#!/usr/bin/env ruby

require "json"
require "net/http"
require "socket"
require "uri"

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 18080
UPSTREAM = URI("http://127.0.0.1:8080/v1/chat/completions")
GLOSSARY_PATH = ENV.fetch("XTRANSLATOR_GLOSSARY", "/tmp/xtranslator-glossary.tsv")
GLOSSARY_PREPEND = ENV.fetch("XTRANSLATOR_GLOSSARY_PREPEND", "/home/onoue/.local/bin/_xTranslator/xtranslator-glossary.local.tsv")
GLOSSARY_LIMIT = ENV.fetch("XTRANSLATOR_GLOSSARY_LIMIT", "40").to_i

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

    glossary[line.downcase]
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
  matched = prefer_longest_entries(
    load_glossary.select { |entry| source_text.include?(entry[:source]) }
  ).first(GLOSSARY_LIMIT)
  return body if matched.empty?

  glossary = matched.map do |entry|
    "- #{entry[:source]} => #{entry[:target]}"
  end.join("\n")

  user_message["content"] = <<~PROMPT.chomp
    一致する用語を翻訳する際は、以下の用語集を必ず使用してください。
    #{glossary}
    用語集の注釈、ファイル名、コメント、括弧、説明、Markdown、箇条書き、番号付け、太字、引用、コードフェンスは出力しないでください。
    <tags> や </tags> などのXML/HTMLタグは追加しないでください。<dur>、<mag>、<a_A>など、ソーステキストに既に存在する山括弧のプレースホルダーのみを保持してください。
    翻訳されたテキストは、ソーステキストと同じ行数で出力してください。
    ソース行がタイトル、呪文名、効果名、アイテム名、または名詞句の場合は、文ではなく日本語のタイトル/名詞句を出力してください。
    「召喚」で始まる呪文名の場合は、「<召喚名>召喚」の形式を推奨します。

    #{user_message["content"]}
  PROMPT

  JSON.dump(payload)
rescue JSON::ParserError
  body
end

def strip_model_markup(text)
  text
    .lines
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

def sanitize_response_body(body, source_text)
  payload = JSON.parse(body)
  choices = payload["choices"]
  return body unless choices.is_a?(Array)

  choices.each do |choice|
    message = choice["message"]
    next unless message.is_a?(Hash) && message["content"].is_a?(String)

    content = strip_model_markup(message["content"])
    message["content"] = strip_unseen_angle_tags(content, source_text)
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

    warn "---- xTranslator request ----"
    warn request_line
    warn headers.inspect
    warn body

    if (direct_body = direct_glossary_response(body))
      warn "---- direct glossary response ----"
      warn direct_body
      write_response(sock, 200, direct_body)
      next
    end

    post = Net::HTTP::Post.new(UPSTREAM)
    post["Content-Type"] = "application/json"
    post["Accept"] = "application/json"
    post["Authorization"] = headers["authorization"] || "Bearer no-key"
    upstream_body = inject_glossary(body)
    warn "---- upstream request ----"
    warn upstream_body

    post.body = upstream_body

    upstream = Net::HTTP.start(UPSTREAM.host, UPSTREAM.port) do |http|
      http.request(post)
    end

    request_payload = JSON.parse(body)
    request_source_text = source_text_from(user_message_from(request_payload)&.fetch("content", ""))
    response_body = sanitize_response_body(upstream.body.to_s, request_source_text)

    warn "---- llama.cpp response #{upstream.code} ----"
    warn upstream.body.to_s
    warn "---- sanitized response ----"
    warn response_body

    write_response(sock, upstream.code.to_i, response_body)
  rescue => e
    warn "proxy error: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    write_response(sock, 500, JSON.dump(error: e.message))
  ensure
    sock.close
  end
end
