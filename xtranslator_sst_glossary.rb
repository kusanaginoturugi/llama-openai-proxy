#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/sst"

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

seen = {}
rows = []

SST.files(root: options[:root], game: options[:game], source: options[:source], dest: options[:dest]).each do |path|
  SST.each_pair(path) do |source, target|
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
