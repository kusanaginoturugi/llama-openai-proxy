# llama-openai-proxy

xTranslator の OpenAI API 枠を llama.cpp（router モード）に向けるための Ruby プロキシ。
xTranslator の辞書（`UserDictionaries/*.sst`）を直接読み、辞書で確定できる訳は辞書から返し、
残りは用語集と公式訳の類似例文をプロンプトに添えて LLM に訳させる。

```
xTranslator (wine) ──POST──▶ proxy 127.0.0.1:8091 ──▶ llama-server router 127.0.0.1:8080
                               ├ SST 辞書: 完全一致 / 用語 / 類似例文
                               ├ 検証 → 指摘付き再試行
                               └ キャッシュ ~/.cache/llama-openai-proxy/translations.jsonl
```

仕様の詳細は [`docs/spec.md`](docs/spec.md)、作業履歴と引き継ぎは [`WORKLOG.md`](WORKLOG.md)。

## Files

| パス | 役割 |
| --- | --- |
| `llama-openai-proxy.rb` | プロキシ本体 |
| `lib/sst.rb` | SST リーダ / 有効辞書の列挙 |
| `lib/dictionary.rb` | 翻訳メモリ・用語照合・類似例文検索 |
| `xtranslator-glossary.local.tsv` | 手動の上書き辞書（SST より優先） |
| `xtranslator_sst_glossary.rb` | SST から用語 TSV を書き出す補助ツール（プロキシには不要） |
| `xtranslator` | xTranslator を日本語ロケールで起動する wine ラッパ |
| `scripts/try.sh` / `scripts/samples.txt` | 動作確認用 |

## Start

```sh
ruby ~/src/llama-openai-proxy/llama-openai-proxy.rb --brief
```

- `--brief` / `-b`: 原文・訳文・どこで訳したか（`glossary` / `cache` / モデル名）だけ表示
- `--dump PATH`: xTranslator からの生リクエストを JSONL で追記（仕様確認用）

起動時にモデルを warmup でロードする。初回だけ数十秒かかる。

## xTranslator settings

OpenAI API タブ（または `UserPrefs/commonApiPrefs.ini`。xTranslator 終了中に編集）:

```txt
OpenAI_URL=http://127.0.0.1:8091/v1/chat/completions
OpenAI_Key=no-key
```

`OpenAI_Model` と `OpenAI_Query` はプロキシが差し替えるので何でもいい。
ただしプロキシは「user メッセージの 1 行目 = クエリ、2 行目以降 = 原文」として扱うので、`OpenAI_Query` は 1 行にする。

`commonApiPrefs.ini` は xTranslator の終了時に上書きされるので、必ず閉じてから編集する（GUI からは URL を変えられない）。

`Misc/ApiTranslator.txt`（xTranslator は書き戻さない。変更後は xTranslator 再起動）:

```txt
OpenAI_CharLimit=6000
OpenAI_ArrayLimit=2
OpenAI_ArrayTimePause=0
```

`OpenAI_CharLimit` を超える文字列は xTranslator が送る前に捨てる（「API の文字数上限を越えているため一部の文字列は無視されます」）。

xTranslator は応答を約 20 秒しか待たない（設定項目なし）。約 2700 文字の本で 16 秒程度なので、それより長い文は 1 回目は切断されて訳が反映されない。
プロキシは切断後も訳を最後まで作ってキャッシュするので、**もう一度同じ文を翻訳すれば即座に反映される**。

## Dictionary

- `~/.local/bin/_xTranslator/UserDictionaries/SkyrimSE/*_english_japanese.sst` を全部読む
- `UserPrefs/SkyrimSE/prefs_vocab_english_japanese.ini` で `name|1` の辞書は除外、並び順が優先順
- xTranslator で辞書を保存すると、次のリクエストで自動的に読み直す（プロキシ再起動不要）
- 手動で直したい訳は `xtranslator-glossary.local.tsv` に `原文<TAB>訳文` で書く

## Try

```sh
scripts/try.sh 8091 < scripts/samples.txt
```

## Environment

| 変数 | 既定値 | |
| --- | --- | --- |
| `XTRANSLATOR_LISTEN_PORT` | `8091` | |
| `XTRANSLATOR_UPSTREAM` | `http://127.0.0.1:8080/v1/chat/completions` | |
| `XTRANSLATOR_MODEL` | `gemma-4-12b-it-qat-imatrix` | router の model ID（`/etc/llama.cpp/models.ini` のセクション名） |
| `XTRANSLATOR_SHORT_MODEL` | 空 | 設定すると短文だけこのモデルへ。`--models-max 1` だと載せ替えが頻発するので非推奨 |
| `XTRANSLATOR_TEMPERATURE` | `0` | |
| `XTRANSLATOR_UPSTREAM_TIMEOUT` | `30` | 秒。read timeout は `これ + max_tokens/25` 秒。超えたら原文をそのまま返す |
| `XTRANSLATOR_RETRIES` | `1` | 検証 NG 時の再試行回数 |
| `XTRANSLATOR_CLIENT_BUDGET` | `18` | 秒。再試行してもこの時間に収まりそうなときだけ再試行する（xTranslator は約 20 秒で切断する） |
| `XTRANSLATOR_GLOSSARY_LIMIT` | `40` | プロンプトに入れる用語の上限 |
| `XTRANSLATOR_EXAMPLE_LIMIT` | `3` | プロンプトに入れる類似例文の数（0 で無効） |
| `XTRANSLATOR_CACHE` | `~/.cache/llama-openai-proxy/translations.jsonl` | 空文字で無効 |
| `XTRANSLATOR_WARMUP` | `1` | `0` で起動時ロードしない |
| `XTRANSLATOR_ROOT` / `GAME` / `SOURCE_LANG` / `DEST_LANG` | `~/.local/bin/_xTranslator` / `SkyrimSE` / `english` / `japanese` | |
| `XTRANSLATOR_GLOSSARY_PREPEND` | リポジトリ内 `xtranslator-glossary.local.tsv` | `:` 区切りで複数可 |

## Reload

- プロキシのコードを変えたら: プロキシ再起動
- 辞書（SST / local TSV）を変えたら: 不要（自動再読込）
- プロンプトや既定モデルを変えて過去訳を捨てたいとき: `rm ~/.cache/llama-openai-proxy/translations.jsonl`
- `Misc/ApiTranslator.txt` を変えたら: xTranslator 再起動
- `/etc/llama.cpp/models.ini` を変えたら: llama.cpp 再起動
