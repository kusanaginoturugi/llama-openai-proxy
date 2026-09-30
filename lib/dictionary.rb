# frozen_string_literal: true

require "set"
require_relative "sst"

# SST 辞書と手動 TSV から、翻訳メモリ・用語集・類似例文を引く。
# 元ファイルの mtime が変わったら refresh! で作り直す。
class Dictionary
  WORD_RE = /[[:alnum:]]+(?:['’][[:alnum:]]+)*/
  STOPWORDS = %w[
    the and for you your are was were with that this have has had not but from they them their
    what when where who will would can could should into out about there then than its his her
    she him our all any some one two just been being more most very also only over such
  ].to_set.freeze
  TERM_MIN_CHARS = 3
  TERM_MAX_CHARS = 80
  TERM_MAX_WORDS = 8
  EXAMPLE_MIN_CHARS = 20
  EXAMPLE_MAX_CHARS = 300
  EXAMPLE_MAX_DF = 400

  attr_reader :memory_size, :term_size, :example_size

  def initialize(root:, game:, source:, dest:, local_paths: [])
    @root = root
    @game = game
    @source = source
    @dest = dest
    @local_paths = local_paths
    @signature = nil
    refresh!
  end

  def self.words(text)
    text.to_s.tr("’", "'").scan(WORD_RE).map(&:downcase)
  end

  def self.term_key(text) = words(text).join(" ")

  # <img src=...> や <font ...> の中身を照合対象から外す（位置は保つ）。
  def self.mask_tags(text) = text.to_s.gsub(/<[^<>]*>/) { |tag| " " * tag.length }

  def paths
    @local_paths.select { |path| File.file?(path) } +
      SST.files(root: @root, game: @game, source: @source, dest: @dest)
  end

  # 元ファイルに変化があれば読み直す。読み直したら true。
  def refresh!
    signature = paths.map { |path| [path, File.mtime(path).to_f, File.size(path)] }
    return false if signature == @signature

    build(signature.map(&:first))
    @signature = signature
    true
  end

  # 1 行（または 1 エントリ全体）の確定訳。無ければ nil。
  def lookup(text)
    text = text.to_s
    return nil if text.strip.empty?

    found = @memory[text] || @memory_ci[text.downcase] || @memory_ci[text.strip.downcase]
    return found if found

    if (m = text.match(/\ASpell Tome: (.+)\z/))
      spell = lookup(m[1])
      return "呪文の書: #{spell}" if spell
    end

    nil
  end

  # 原文中に出てくる用語を左から最長一致で拾う。
  # 1 語の用語は、原文側で大文字始まりで、かつ 文中にある か 訳がカタカナを含む（固有名詞の音訳）ときだけ採用する。
  # "Speak = 話す" のような文頭の一般語を拾わないため。
  def match_terms(text, limit: 40)
    text = Dictionary.mask_tags(text).tr("’", "'")
    tokens = []
    text.scan(WORD_RE) { tokens << [Regexp.last_match[0], Regexp.last_match.begin(0)] }
    lowered = tokens.map { |word, _| word.downcase }

    found = {}
    i = 0
    while i < tokens.length
      hit = nil
      [@max_term_words, tokens.length - i].min.downto(1) do |n|
        entry = @terms[lowered[i, n].join(" ")]
        next unless entry
        next if n == 1 && !entry[:local] && !proper_noun?(text, tokens[i], entry[:target])

        hit = [entry, n]
        break
      end

      if hit
        found[Dictionary.term_key(hit[0][:source])] ||= hit[0]
        i += hit[1]
      else
        i += 1
      end
    end

    found.values.first(limit)
  end

  # 原文と珍しい単語を多く共有する既訳を返す。文体と固有名詞の訳し方を揃える用。
  def similar_examples(text, limit: 3, min_score: 6.0)
    return [] if limit <= 0

    query = Dictionary.words(Dictionary.mask_tags(text)).reject { |w| w.length < 3 || STOPWORDS.include?(w) }.uniq
    scores = Hash.new(0.0)
    query.each do |word|
      ids = @postings[word]
      next if ids.nil? || ids.length > EXAMPLE_MAX_DF

      idf = Math.log(@examples.length.to_f / ids.length)
      ids.each { |id| scores[id] += idf }
    end

    text_key = text.to_s.strip.downcase
    scores
      .map { |id, score| [id, score / Math.sqrt(@example_lengths[id])] }
      .select { |_, score| score >= min_score / Math.sqrt(query.length.clamp(1, 16)) }
      .sort_by { |id, score| [-score, id] }
      .map { |id, _| @examples[id] }
      .reject { |source, _| source.strip.downcase == text_key }
      .first(limit)
  end

  private

  def proper_noun?(text, (word, offset), target)
    return false unless word.match?(/\A[[:upper:]]/)
    return true if target.match?(/\p{Katakana}/)

    before = text[0, offset].rstrip
    !before.empty? && !before.match?(/[.!?:;"“]\z/)
  end

  def build(paths)
    @memory = {}
    @memory_ci = {}
    @terms = {}
    @examples = []
    @example_lengths = []
    @postings = Hash.new { |h, k| h[k] = [] }

    paths.each do |path|
      local = !path.end_with?(".sst")
      each_pair(path) { |source, target| add(source, target, local) }
    rescue => e
      warn "dictionary: skip #{path}: #{e.message}"
    end

    @postings.default_proc = nil
    @max_term_words = @terms.keys.map { |k| k.count(" ") + 1 }.max || 1
    @memory_size = @memory.size
    @term_size = @terms.size
    @example_size = @examples.size
  end

  def each_pair(path, &block)
    return SST.each_pair(path, &block) if path.end_with?(".sst")

    File.readlines(path, chomp: true, encoding: "bom|utf-8").each do |line|
      next if line.strip.empty? || line.start_with?("#")

      source, target = line.split("\t", 3)
      yield source.to_s, target.to_s
    end
  end

  def add(source, target, local)
    return if source.empty? || target.empty? || target == "-" || source == target

    first = !@memory.key?(source)
    @memory[source] ||= target
    @memory_ci[source.downcase] ||= target
    add_term(source, target, local) if local || term_like?(source)
    add_example(source, target) if first && example_like?(source, target)
  end

  def add_term(source, target, local)
    key = Dictionary.term_key(source)
    return if key.empty? || key.count(" ") >= TERM_MAX_WORDS

    @terms[key] ||= { source: source, target: target, local: local }
  end

  def add_example(source, target)
    id = @examples.length
    words = Dictionary.words(source).reject { |w| w.length < 3 || STOPWORDS.include?(w) }.uniq
    return if words.length < 3

    @examples << [source, target]
    @example_lengths << words.length
    words.each { |word| @postings[word] << id }
  end

  # 旧 xtranslator_sst_glossary.rb の usable_entry? と同じ基準。
  def term_like?(source)
    return false if source.length < TERM_MIN_CHARS || source.length > TERM_MAX_CHARS
    return false if source.match?(/[\r\n<>]/)
    return false if source.count(" ") > 6
    return false if source.match?(/[.!?。！？]\z/)
    return false if source == source.downcase

    true
  end

  def example_like?(source, target)
    return false if source.length < EXAMPLE_MIN_CHARS || source.length > EXAMPLE_MAX_CHARS
    return false if target.length > EXAMPLE_MAX_CHARS
    return false unless target.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)

    source.include?(" ")
  end
end
