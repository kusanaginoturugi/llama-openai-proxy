#!/usr/bin/env ruby

require "json"
require "net/http"
require "socket"
require "uri"

BRIEF_LOG = !!(ARGV.delete("--brief") || ARGV.delete("-b"))
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 18080
UPSTREAM = URI("http://127.0.0.1:8080/v1/chat/completions")
GLOSSARY_PATH = ENV.fetch("XTRANSLATOR_GLOSSARY", "/tmp/xtranslator-glossary.tsv")
GLOSSARY_PREPEND = ENV.fetch("XTRANSLATOR_GLOSSARY_PREPEND", "/home/onoue/src/llama-openai-proxy/xtranslator-glossary.local.tsv")
GLOSSARY_LIMIT = ENV.fetch("XTRANSLATOR_GLOSSARY_LIMIT", "40").to_i
SHORT_MODEL = ENV.fetch("XTRANSLATOR_SHORT_MODEL", "translategemma-4B")
LONG_MODEL = ENV.fetch("XTRANSLATOR_LONG_MODEL", "translategemma-12B")
SHORT_MODEL_MAX_LINES = ENV.fetch("XTRANSLATOR_SHORT_MODEL_MAX_LINES", "2").to_i
SHORT_MODEL_MAX_CHARS = ENV.fetch("XTRANSLATOR_SHORT_MODEL_MAX_CHARS", "160").to_i

def load_glossary
  paths = GLOSSARY_PREPEND.split(":") + [GLOSSARY_PATH]
  seen = {}
  paths.flat_map do |path|
    next [] unless File.file?(path)

    File.readlines(path, chomp: true).filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      source, target = line.split("\t", 3)
      next if source.to_s.empty? || target.to_s.empty?
      next if seen[source.downcase]

      seen[source.downcase] = true
      { source: source, target: target }
    end
  end
end

def source_text_from(content)
  content.to_s.split(/\r?\n/, 2)[1].to_s
end

def user_message_from(payload)
  messages = payload["messages"]
  return nil unless messages.is_a?(Array)

  messages.find { |m| m.is_a?(Hash) && m["role"] == "user" && m["content"].is_a?(String) }
end

def prefer_longest_entries(entries)
  entries
    .sort_by { |entry| [-entry[:source].length, entry[:source].downcase] }
    .each_with_object([]) do |entry, selected|
      source = entry[:source].downcase
      next if selected.any? { |picked| picked[:source].downcase.include?(source) }

      selected << entry
    end
end

def model_for_source_text(source_text)
  lines = source_text.to_s.split(/\r?\n/, -1)
  compact_text = source_text.to_s.gsub(/\s+/, "")

  if lines.length <= SHORT_MODEL_MAX_LINES && compact_text.length <= SHORT_MODEL_MAX_CHARS
    SHORT_MODEL
  else
    LONG_MODEL
  end
end

def glossary_translation(glossary, line)
  direct = glossary[line.downcase]
  return direct if direct

  if line.start_with?("Spell Tome: ")
    spell = line.delete_prefix("Spell Tome: ")
    translated_spell = glossary[spell.downcase]
    return "呪文の書: #{translated_spell}" if translated_spell
  end

  nil
end

def direct_glossary_response(body)
  payload = JSON.parse(body)
  user_message = user_message_from(payload)
  return nil unless user_message

  glossary = {}
  load_glossary.each { |entry| glossary[entry[:source].downcase] ||= entry[:target] }

  source_text = source_text_from(user_message["content"])
  lines = source_text.split(/\r?\n/, -1)
  return nil if lines.empty?

  translated = lines.map do |line|
    next "" if line.empty?

    glossary_translation(glossary, line)
  end
  return nil if translated.any?(&:nil?)

  response = {
    choices: [
      {
        finish_reason: "stop",
        index: 0,
        message: {
          role: "assistant",
          content: translated.join("\n")
        }
      }
    ],
    object: "chat.completion",
    model: payload["model"] || "glossary"
  }

  JSON.dump(response)
rescue JSON::ParserError
  nil
end

def inject_glossary(body)
  payload = JSON.parse(body)
  user_message = user_message_from(payload)
  return body unless user_message

  source_text = source_text_from(user_message["content"])
  payload["model"] = model_for_source_text(source_text)
  matched = prefer_longest_entries(
    load_glossary.select { |entry| source_text.include?(entry[:source]) }
  ).first(GLOSSARY_LIMIT)
  glossary = matched.map { |entry| "#{entry[:source]}\t#{entry[:target]}" }.join("\n")
  glossary_section = matched.empty? ? "" : "\nGlossary entries that must be used exactly:\n#{glossary}\n"

  user_message["content"] = <<~PROMPT.chomp
    Translate the source text from Skyrim into Japanese.
    Output only the translated text.
    Do not acknowledge the request.
    Do not copy the source text unless it is an untranslatable proper noun.
    Do not add labels such as "translation", "result", or "translated text".
    Do not add explanations, notes, comments, filenames, quotes, Markdown, bullets, numbering, or code fences.
    Keep exactly the same number of lines as the source text.
    Preserve only angle-bracket placeholders that already exist in the source text, such as <dur>, <mag>, and <a_A>.
    For titles, spell names, effect names, item names, and noun phrases, output a Japanese title or noun phrase, not a full sentence.
    For spell names starting with "Conjure", prefer the Japanese form "<summoned name>召喚".
    #{glossary_section}
    Source text:

    #{source_text}
  PROMPT

  JSON.dump(payload)
rescue JSON::ParserError
  body
end

def strip_model_markup(text)
  text
    .lines
    .reject { |line| line.match?(/\A\s*```/) }
    .reject { |line| line.include?("=>") }
    .join
    .gsub(/(?m)^\s*[-*•]\s+/, "")
    .gsub(/(?m)^\s*\d+[.)]\s+/, "")
    .gsub(/(?m)^\s*<\d+>\s+/, "")
    .gsub(/\*\*([^*\r\n]+)\*\*/, "\\1")
    .gsub(/__([^_\r\n]+)__/, "\\1")
    .gsub(/`([^`\r\n]+)`/, "\\1")
    .sub(/\r?\n+\z/, "")
end

def angle_tags(text)
  text.to_s.scan(/<[^<>\r\n]+>/).uniq
end

def strip_unseen_angle_tags(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)

  if source_lines.length == output_lines.length
    return output_lines.each_with_index.map do |line, index|
      allowed = angle_tags(source_lines[index])
      line.gsub(/<[^<>\r\n]+>/) { |tag| allowed.include?(tag) ? tag : "" }
    end.join("\n")
  end

  allowed = angle_tags(source_text)
  text.gsub(/<[^<>\r\n]+>/) { |tag| allowed.include?(tag) ? tag : "" }
end

def enforce_source_line_count(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)
  return text if source_lines.length == output_lines.length

  compact_lines = output_lines.map(&:strip).reject(&:empty?)
  return compact_lines.join if source_lines.length == 1
  return compact_lines.join("\n") if source_lines.length == compact_lines.length

  text
end

def strip_added_terminal_periods(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)
  return text unless source_lines.length == output_lines.length

  output_lines.each_with_index.map do |line, index|
    source_line = source_lines[index].rstrip
    next line if source_line.match?(/[.。]\z/)

    line.sub(/[.。]\z/, "")
  end.join("\n")
end

def sanitize_response_body(body, source_text)
  payload = JSON.parse(body)
  choices = payload["choices"]
  return body unless choices.is_a?(Array)

  choices.each do |choice|
    message = choice["message"]
    next unless message.is_a?(Hash) && message["content"].is_a?(String)

    content = strip_model_markup(message["content"])
    content = strip_unseen_angle_tags(content, source_text)
    content = enforce_source_line_count(content, source_text)
    message["content"] = strip_added_terminal_periods(content, source_text)
  end

  JSON.dump(payload)
rescue JSON::ParserError
  body
end

def read_request(sock)
  head = +""
  head << sock.readpartial(1024) until head.include?("\r\n\r\n")
  header, rest = head.split("\r\n\r\n", 2)
  lines = header.lines.map(&:chomp)
  request_line = lines.shift
  headers = {}

  lines.each do |line|
    key, value = line.split(":", 2)
    headers[key.downcase] = value.to_s.strip if key
  end

  length = headers["content-length"].to_i
  body = rest.to_s
  body << sock.read(length - body.bytesize) while body.bytesize < length

  [request_line, headers, body]
end

def write_response(sock, status, body)
  reason = status == 200 ? "OK" : "Error"
  bytes = body.b
  sock.write "HTTP/1.1 #{status} #{reason}\r\n"
  sock.write "Content-Type: application/json; charset=utf-8\r\n"
  sock.write "Content-Length: #{bytes.bytesize}\r\n"
  sock.write "Connection: close\r\n"
  sock.write "\r\n"
  sock.write bytes
end

def client_disconnected?(error)
  error.is_a?(Errno::EPIPE) || error.is_a?(Errno::ECONNRESET) || error.is_a?(IOError)
end

def log_verbose(*lines)
  return if BRIEF_LOG

  lines.each { |line| warn line }
end

def response_text_from(body)
  payload = JSON.parse(body)
  choices = payload["choices"]
  return nil unless choices.is_a?(Array)

  message = choices.dig(0, "message")
  return nil unless message.is_a?(Hash)

  message["content"]
rescue JSON::ParserError
  nil
end

def brief_style(text, code)
  return text unless $stderr.tty?

  "\e[#{code}m#{text}\e[0m"
end

def log_brief_translation(source_text, response_body, model)
  return unless BRIEF_LOG

  warn brief_style("モデル: #{model}", "1;35")
  warn brief_style("ソース", "1;32")
  warn source_text
  warn brief_style("訳文", "1;36")
  warn(response_text_from(response_body) || response_body)
  warn brief_style("────────────────", "2")
end

server = TCPServer.new(LISTEN_HOST, LISTEN_PORT)
warn "listening on http://#{LISTEN_HOST}:#{LISTEN_PORT}/v1/chat/completions"

trap("INT") do
  warn "\nbye"
  exit
end

loop do
  sock = server.accept

  begin
    request_line, headers, body = read_request(sock)
    request_payload = JSON.parse(body)
    request_source_text = source_text_from(user_message_from(request_payload)&.fetch("content", ""))

    log_verbose(
      "---- xTranslator request ----",
      request_line,
      headers.inspect,
      body
    )

    if (direct_body = direct_glossary_response(body))
      log_verbose("---- direct glossary response ----", direct_body)
      log_brief_translation(request_source_text, direct_body, "glossary")
      write_response(sock, 200, direct_body)
      next
    end

    selected_model = model_for_source_text(request_source_text)
    post = Net::HTTP::Post.new(UPSTREAM)
    post["Content-Type"] = "application/json"
    post["Accept"] = "application/json"
    post["Authorization"] = headers["authorization"] || "Bearer no-key"
    upstream_body = inject_glossary(body)
    log_verbose("---- upstream request #{selected_model} ----", upstream_body)

    post.body = upstream_body

    upstream = Net::HTTP.start(UPSTREAM.host, UPSTREAM.port) do |http|
      http.request(post)
    end

    response_body = sanitize_response_body(upstream.body.to_s, request_source_text)

    log_verbose(
      "---- llama.cpp response #{upstream.code} ----",
      upstream.body.to_s,
      "---- sanitized response ----",
      response_body
    )
    log_brief_translation(request_source_text, response_body, selected_model)

    write_response(sock, upstream.code.to_i, response_body)
  rescue => e
    if client_disconnected?(e)
      warn "client disconnected: #{e.class}: #{e.message}"
      next
    end

    warn "proxy error: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    begin
      write_response(sock, 500, JSON.dump(error: e.message))
    rescue => write_error
      raise write_error unless client_disconnected?(write_error)

      warn "client disconnected while writing error response: #{write_error.class}: #{write_error.message}"
    end
  ensure
    sock.close
  end
end
