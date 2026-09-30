# llama-openai-proxy

xTranslator の OpenAI API 枠を llama.cpp（router モード）に向けるための Ruby プロキシ。
xTranslator の辞書（`UserDictionaries/*.sst`）から書き出したスナップショットを使い、辞書で確定できる訳は辞書から返し、
残りは用語集と公式訳の類似例文をプロンプトに添えて LLM に訳させる。

```
xTranslator (wine) ──POST──▶ proxy 127.0.0.1:8091 ──▶ llama-server router 127.0.0.1:8080
                               ├ 辞書スナップショット: 完全一致 / 用語 / 類似例文
                               ├ 検証 → 指摘付き再試行
                               └ キャッシュ ~/.cache/llama-openai-proxy/translations.jsonl

SST 保存 ─▶ llama-openai-proxy-dict.path ─▶ xtranslator_sst_glossary.rb --format jsonl
          ─▶ ~/.local/share/llama-openai-proxy/dictionary.jsonl ─▶ proxy が mtime を見て再読込
```

仕様の詳細は [`docs/spec.md`](docs/spec.md)、作業履歴と引き継ぎは [`WORKLOG.md`](WORKLOG.md)。

## Files

| パス | 役割 |
| --- | --- |
| `llama-openai-proxy.rb` | プロキシ本体 |
| `systemd/llama-openai-proxy.service` | プロキシの user サービス |
| `systemd/llama-openai-proxy-dict.{path,service}` | SST の変更を監視して辞書スナップショットを書き出す |
| `xtranslator_sst_glossary.rb` | SST の書き出しツール（`--format jsonl` でスナップショット、`tsv` で用語 TSV） |
| `lib/sst.rb` | SST リーダ / 有効辞書の列挙（書き出しツール用） |
| `lib/dictionary.rb` | スナップショットを読み、翻訳メモリ・用語照合・類似例文検索をする |
| `xtranslator-glossary.local.tsv` | 手動の上書き辞書（スナップショットより優先） |
| `xtranslator` | xTranslator を日本語ロケールで起動する wine ラッパ |
| `scripts/try.sh` / `scripts/samples.txt` | 動作確認用 |

## Start

systemd の user サービスとして常駐させている（`systemd/`）。

```sh
# 初回インストール
cp systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now llama-openai-proxy-dict.path llama-openai-proxy

systemctl --user restart llama-openai-proxy   # コード変更後
journalctl --user -u llama-openai-proxy -f -o cat   # 訳のログ（--brief 形式）
```

サービスでは `XTRANSLATOR_WARMUP=0` にしている（ログイン直後に VRAM を掴まないため）。
モデルが載っていない状態での最初の 1 件は xTranslator の timeout を超えることがある。その場合はもう一度翻訳すればキャッシュから返る。

手で起動する場合（サービスを止めてから）:

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

プロキシは SST を直接読まない。`xtranslator_sst_glossary.rb --format jsonl` が書き出した
`~/.local/share/llama-openai-proxy/dictionary.jsonl`（1 行 1 件、`source` / `target` / `file`）を読む。

- 書き出し元: `~/.local/bin/_xTranslator/UserDictionaries/SkyrimSE/*_english_japanese.sst` 全部
  - `UserPrefs/SkyrimSE/prefs_vocab_english_japanese.ini` で `name|1` の辞書は除外、並び順が優先順。同じ原文は先勝ち
- 自動更新: `llama-openai-proxy-dict.path` が SST のディレクトリと ini を監視（`PathChanged`）し、
  変更があれば 2 秒待ってから書き出す。書き出しは一時ファイル経由で差し替えるので、読み込み途中に壊れたファイルは見えない
- プロキシの起動時にも 1 回書き出す（ログアウト中の変更を拾う）
- プロキシはスナップショットの mtime が変わったら、次のリクエストで読み直す（再起動不要）
- 手動で今すぐ更新: `systemctl --user start llama-openai-proxy-dict`
- 手動で直したい訳は `xtranslator-glossary.local.tsv` に `原文<TAB>訳文` で書く（これも自動で読み直す）

### 作業中辞書（session）

SST を保存するのは mod を訳し終えてからが多いので、それまでの訳をプロキシ自身が貯めて使い回す。

- 検証を通った LLM の訳を 1 行ずつ `~/.local/share/llama-openai-proxy/session.jsonl` に追記する
- 優先度は 手動 TSV ＞ スナップショット ＞ 作業中辞書。完全一致・用語・類似例文のすべてに使う
  - mod 固有の NPC 名やアイテム名を一度訳すと、以降の文ではその訳を用語として強制する
  - 類似例文 3 件のうち最大 2 件を作業中辞書から優先して選ぶ（`XTRANSLATOR_SESSION_EXAMPLE_LIMIT`）
- SST を保存してスナップショットの**中身が変わったら**空にする（訳は SST 側に入ったとみなす）。再起動による同じ内容の書き出し直しでは消さない
- 手動で捨てる: `command rm -f ~/.local/share/llama-openai-proxy/session.jsonl`（次のリクエストでプロキシが気づく）
- xTranslator 上で手直しした訳は、SST を保存するまでプロキシには見えない

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
| `XTRANSLATOR_DICTIONARY` | `~/.local/share/llama-openai-proxy/dictionary.jsonl` | 辞書スナップショット |
| `XTRANSLATOR_SESSION` | `~/.local/share/llama-openai-proxy/session.jsonl` | 作業中辞書。空文字で無効 |
| `XTRANSLATOR_SESSION_EXAMPLE_LIMIT` | `2` | 類似例文のうち作業中辞書から優先して入れる件数 |
| `XTRANSLATOR_GLOSSARY_PREPEND` | リポジトリ内 `xtranslator-glossary.local.tsv` | `:` 区切りで複数可 |

## Reload

- プロキシのコードを変えたら: `systemctl --user restart llama-openai-proxy`
- 辞書（SST / local TSV）を変えたら: 不要（path unit が書き出し、プロキシが自動で再読込）
- `systemd/` を変えたら: `cp systemd/* ~/.config/systemd/user/ && systemctl --user daemon-reload`
- プロンプトや既定モデルを変えて過去訳を捨てたいとき: `rm ~/.cache/llama-openai-proxy/translations.jsonl`
- `Misc/ApiTranslator.txt` を変えたら: xTranslator 再起動
- `/etc/llama.cpp/models.ini` を変えたら: llama.cpp 再起動
