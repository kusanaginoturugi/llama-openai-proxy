#!/bin/sh
# 1 行 1 エントリで標準入力を xTranslator と同じ形でプロキシに投げ、訳とラベルを出す。
# usage: scripts/try.sh [PORT] < samples.txt
port=${1:-8091}
while IFS= read -r line; do
  [ -z "$line" ] && continue
  body=$(ruby -rjson -e 'puts JSON.dump(model: "x", messages: [{role: "user", content: "Translate to japanese:\n" + ARGV[0]}])' "$line")
  printf '%s\n  => ' "$line"
  curl -s -m 180 "http://127.0.0.1:$port/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" |
    ruby -rjson -e 'j = JSON.parse(STDIN.read); puts "#{j.dig("choices", 0, "message", "content")}   [#{j["model"]}]"'
done
