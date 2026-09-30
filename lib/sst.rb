# frozen_string_literal: true

# xTranslator の UserDictionaries/*.sst を読む。
module SST
  HEADERS = {
    "SSU2" => 1, "SSU3" => 2, "SSU4" => 3, "SSU5" => 4,
    "SSU6" => 5, "SSU7" => 6, "SSU8" => 7, "SSU9" => 8
  }.freeze

  class Reader
    def initialize(path)
      @path = path
      @data = File.binread(path)
      @pos = 0
    end

    def eof? = @pos >= @data.bytesize

    def read(n)
      raise EOFError, "#{@path}: unexpected EOF" if @pos + n > @data.bytesize

      @data.byteslice(@pos, n).tap { @pos += n }
    end

    def u8 = read(1).unpack1("C")
    def i32 = read(4).unpack1("l<")
    def u32 = read(4).unpack1("L<")
    def u16 = read(2).unpack1("S<")

    def utf16_string
      size = i32
      return "" if size <= 0

      read(size).force_encoding("UTF-16LE").encode("UTF-8", invalid: :replace, undef: :replace)
    end
  end

  module_function

  def each_pair(path)
    reader = Reader.new(path)
    header = reader.read(4)
    version = HEADERS.fetch(header) { raise "#{path}: unsupported SST header #{header.inspect}" }

    reader.u8 if version > 3
    reader.i32.times { reader.utf16_string } if version > 7
    if version > 6
      reader.i32.times do
        reader.i32
        reader.utf16_string
      end
    end

    until reader.eof?
      reader.u8

      if version > 1
        reader.i32
        reader.u32
        reader.u32 if version > 4
        reader.u32
        reader.u16 if version > 2
        if version > 3
          reader.u16
          reader.u32
        end
        reader.u8 if version > 5
      end

      reader.u8
      source = reader.utf16_string
      target = reader.utf16_string
      yield source, target
    end
  end

  # prefs_vocab_*.ini の [[name, disabled?], ...]。ini の並び = 優先順。
  def vocab_prefs(root, game, source, dest)
    path = File.join(root, "UserPrefs", game, "prefs_vocab_#{source}_#{dest}.ini")
    return [] unless File.file?(path)

    File.readlines(path, chomp: true, encoding: "bom|utf-8").filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?("*")

      name, flag = line.split("|", 2)
      [name, flag.to_s.start_with?("1")] unless name.to_s.empty?
    end
  end

  # ini に載っている辞書を ini 順に、載っていない辞書を名前順に後ろへ。無効 (name|1) は除外。
  def files(root:, game:, source:, dest:)
    dir = File.join(root, "UserDictionaries", game)
    suffix = "_#{source}_#{dest}.sst"
    prefs = vocab_prefs(root, game, source, dest)
    order = prefs.map(&:first)
    disabled = prefs.select(&:last).map(&:first)

    Dir[File.join(dir, "*#{suffix}")]
      .map { |path| [File.basename(path, suffix), path] }
      .reject { |name, _| disabled.include?(name) }
      .sort_by { |name, _| [order.index(name) || order.length, name] }
      .map(&:last)
  end
end
