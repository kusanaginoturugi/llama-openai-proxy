#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

HEADERS = {
  "SSU2" => 1,
  "SSU3" => 2,
  "SSU4" => 3,
  "SSU5" => 4,
  "SSU6" => 5,
  "SSU7" => 6,
  "SSU8" => 7,
  "SSU9" => 8
}.freeze

options = {
  game: "SkyrimSE",
  source: "english",
  dest: "japanese",
  root: File.expand_path("~/.local/bin/_xTranslator"),
  output: "/tmp/xtranslator-glossary.tsv",
  max_chars: 80,
  min_chars: 4,
  all: false
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]"
  o.on("--root PATH", "xTranslator directory") { |v| options[:root] = v }
  o.on("--game NAME", "Game folder, default: SkyrimSE") { |v| options[:game] = v }
  o.on("--source LANG", "Source language, default: english") { |v| options[:source] = v }
  o.on("--dest LANG", "Destination language, default: japanese") { |v| options[:dest] = v }
  o.on("-o", "--output PATH", "Output TSV, default: /tmp/xtranslator-glossary.tsv") { |v| options[:output] = v }
  o.on("--max-chars N", Integer, "Max source length, default: 80") { |v| options[:max_chars] = v }
  o.on("--min-chars N", Integer, "Min source length, default: 4") { |v| options[:min_chars] = v }
  o.on("--all", "Include sentence-like entries too") { options[:all] = true }
end.parse!

class Reader
  def initialize(path)
    @path = path
    @data = File.binread(path)
    @pos = 0
  end

  attr_reader :path

  def eof?
    @pos >= @data.bytesize
  end

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

def skip_string_list(reader)
  reader.i32.times { reader.utf16_string }
end

def skip_colab_labels(reader)
  reader.i32.times do
    reader.i32
    reader.utf16_string
  end
end

def each_sst_pair(path)
  reader = Reader.new(path)
  header = reader.read(4)
  version = HEADERS.fetch(header) { raise "#{path}: unsupported SST header #{header.inspect}" }

  reader.u8 if version > 3
  skip_string_list(reader) if version > 7
  skip_colab_labels(reader) if version > 6

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

def usable_entry?(source, target, options)
  return false if source.empty? || target.empty?
  return false if source == target
  return false if target == "-"
  return false if source.length < options[:min_chars] || source.length > options[:max_chars]
  return true if options[:all]

  return false if source.match?(/[\r\n]/)
  return false if source.count(" ") > 6
  return false if source.match?(/[.!?。！？]$/)
  return false if source == source.downcase

  true
end

def enabled_vocab_names(options)
  path = File.join(options[:root], "UserPrefs", options[:game], "prefs_vocab_#{options[:source]}_#{options[:dest]}.ini")
  return [] unless File.file?(path)

  File.readlines(path, chomp: true, encoding: "bom|utf-8").filter_map do |line|
    line = line.strip
    next if line.empty? || line.start_with?("*")

    name, enabled = line.split("|", 2)
    next if name.to_s.empty? || enabled.to_s.start_with?("1")

    name
  end
end

def sst_files(options)
  dir = File.join(options[:root], "UserDictionaries", options[:game])
  suffix = "_#{options[:source]}_#{options[:dest]}.sst"
  names = enabled_vocab_names(options)

  files = if names.empty?
            Dir[File.join(dir, "*#{suffix}")].sort
          else
            names.map { |name| File.join(dir, "#{name}#{suffix}") }
          end

  files.select { |path| File.file?(path) }
end

seen = {}
rows = []

sst_files(options).each do |path|
  each_sst_pair(path) do |source, target|
    next unless usable_entry?(source, target, options)
    next if seen.key?(source.downcase)

    seen[source.downcase] = true
    rows << [source, target]
  end
rescue => e
  warn "skip #{path}: #{e.message}"
end

File.open(options[:output], "w:utf-8") do |file|
  rows.sort_by { |source, _target| [source.downcase.length, source.downcase] }.each do |source, target|
    file.puts [source, target].join("\t")
  end
end

warn "wrote #{rows.length} entries to #{options[:output]}"
