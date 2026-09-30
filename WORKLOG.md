# Work Log

## 2026-09-30 llama.cpp router 対応と精度向上

Plan:

- ollama 時代の設定（port 18080、`translategemma-4B/12B`、`/tmp` の TSV）を今の llama.cpp router 構成に合わせる。
- SST を直接読み、翻訳メモリ・用語・類似例文で LLM に基準データを渡す。
- 検証と再試行、キャッシュで品質と速度を上げる。

Findings（着手時の状態）:

- router の model ID は小文字（`translategemma-12b`）で、旧設定の `translategemma-12B` は `model not found` になっていた。
- `/tmp/xtranslator-glossary.tsv` は再起動で消えていて、実際に効いていたのは手動 TSV の 14 件だけだった。
- router は `--models-max 1` なので、4B と 12B を振り分けるとモデルの載せ替えが頻発する。timeout の原因である可能性が高い。
- `8090` は voicenews の http.server と tailscale serve が使っているので、`8091` にした。

Record:

- `lib/sst.rb`: SST リーダを切り出した。ini にない SST も読み、`name|1` だけを除外、ini 順を優先順にした。
- `lib/dictionary.rb`: 翻訳メモリ（77k）、用語（20k）、類似例文（57k）。起動 2 秒、照合は数 ms。mtime を見て自動で再読込する。
- `llama-openai-proxy.rb`:
  - port 8091
  - 既定モデルを `gemma-4-12b-it-qat-imatrix` に（比較結果は `docs/spec.md`）
  - temperature 0、行単位の部分解決、検証と再試行、JSONL キャッシュ、warmup、`--dump` を追加
- `xtranslator_sst_glossary.rb` は `lib/sst.rb` を使うようにした。生成物の `xtranslator-glossary.tsv` は追跡から外した。
- `scripts/try.sh` と `scripts/samples.txt` を追加。
- `README.md` を書き直し、`docs/spec.md` を新規作成。

Handoff:

- xTranslator の `OpenAI_URL` はまだ `:18080` のまま（作業中は xTranslator が起動していたので ini を触っていない）。GUI で `:8091` に変える。
- 未検証: xTranslator の実リクエスト形式（特に `ArrayLimit=2` のときの連結方法）。`--dump` で採って `docs/spec.md` を更新する。
- 未検証: `prefs_vocab_*.ini` の `|1` が「無効」を意味するという前提（旧実装からの引き継ぎ）。
- `~/.local/bin/llama-openai-proxy.rb` は 7/13 の古い版で、どのコミットとも一致しない。まだ残してある。
- 今後の候補: 類似例文の選び方を embedding（`embeddinggemma-300M` が router にある）に置き換える。キャッシュのキーに辞書の版を含める。

## 2026-07-15 xTranslator proxy hardening

Plan:

- Keep xTranslator API prompts minimal and move translation control into the proxy.
- Bypass llama.cpp when glossary entries fully cover the request.
- Add response cleanup for common LLM formatting drift.
- Add brief translation logs for bulk translation checks.
- Route short requests to `translategemma-4B` and longer requests to `translategemma-12B`.

Record:

- Added glossary direct responses, including `Spell Tome: <spell>` handling.
- Added proxy-side prompt injection even when no glossary term matches.
- Added cleanup for Markdown/code fences, extra tags, added terminal periods, and line count drift.
- Added `--brief` / `-b` logging with source, translation, and selected model.
- Added short/long model routing with environment overrides:
  - `XTRANSLATOR_SHORT_MODEL`
  - `XTRANSLATOR_LONG_MODEL`
  - `XTRANSLATOR_SHORT_MODEL_MAX_LINES`
  - `XTRANSLATOR_SHORT_MODEL_MAX_CHARS`
- Added local glossary overrides for observed bad translations.
- Updated `README.md` with current proxy behavior and xTranslator settings.

Handoff:

- Restart the proxy after `llama-openai-proxy.rb` changes.
- Restart xTranslator after changing `Misc/ApiTranslator.txt`.
- Restart llama.cpp after changing `/etc/llama.cpp/models.ini`.
- Current recommended xTranslator API batch settings are `OpenAI_CharLimit=2000` and `OpenAI_ArrayLimit=2`.
- `--brief` logs should show `モデル: translategemma-4B`, `モデル: translategemma-12B`, or `モデル: glossary`.
