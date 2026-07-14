# xTranslator local llama.cpp translation setup

このフォルダの xTranslator は、OpenAI API 枠を llama.cpp の OpenAI 互換 API に向けて使う。

## Files

- `~/.local/bin/llama-openai-proxy.rb`
  - xTranslator と llama.cpp の間に挟む Ruby プロキシ。
  - Wine/Delphi REST と llama.cpp の応答相性を避ける。
  - 辞書 TSV をプロンプトに注入する。
  - 辞書に完全一致した行は llama.cpp に投げず、そのまま辞書訳を返す。

- `~/.local/bin/_xTranslator/xtranslator_sst_glossary.rb`
  - xTranslator の `UserDictionaries/*.sst` から TSV 辞書を生成する。

- `/tmp/xtranslator-glossary.tsv`
  - 自動生成の辞書。再起動で消えてよい。

- `~/.local/bin/_xTranslator/xtranslator-glossary.local.tsv`
  - 手動上書き辞書。自動生成より優先される。

## Start proxy

```sh
ruby ~/.local/bin/llama-openai-proxy.rb
```

ログを原文と訳文だけに絞る:

```sh
ruby ~/.local/bin/llama-openai-proxy.rb --brief
ruby ~/.local/bin/llama-openai-proxy.rb -b
```

TTY では `モデル`、`ソース`、`訳文` に色が付く。

## Generate glossary

SkyrimSE english -> japanese:

```sh
ruby ~/.local/bin/_xTranslator/xtranslator_sst_glossary.rb \
  --game SkyrimSE \
  --source english \
  --dest japanese \
  -o /tmp/xtranslator-glossary.tsv
```

xTranslator で辞書を保存したあと、これを再実行すると反映される。
プロキシはリクエストごとに TSV を読み直すので、プロキシ再起動は不要。

## Manual glossary override

`~/.local/bin/_xTranslator/xtranslator-glossary.local.tsv` に TSV で書く。

```txt
Conjure Dread Gargoyle	ドレッド・ガーゴイル召喚
Dread Gargoyle	ドレッド・ガーゴイル
```

完全一致した行は LLM に投げず、この訳を直接返す。

## Proxy behavior

プロキシは xTranslator から来た本文をそのまま llama.cpp に流さない。

- xTranslator の `OpenAI_Query` 部分は翻訳対象から外し、原文だけを `Source text` として渡す。
- 用語集に完全一致した行は llama.cpp に投げず、辞書訳を直接返す。
- 複数行リクエストでは、全行が辞書で解決できた場合だけ直接返す。1行でも未解決ならリクエスト全体を llama.cpp に回す。
- `Spell Tome: <辞書にある呪文名>` は例外的に `呪文の書: <呪文名の訳>` として直接返す。
- 2行以下かつ空白抜き160文字以下の短文は `translategemma-4B`、それ以外は `translategemma-12B` に自動で振り分ける。
- llama.cpp に回す場合も、用語集ヒットの有無に関係なく、プロキシ側で英語の出力制約プロンプトを注入する。
- 用語集ヒットがある場合は、最大 `XTRANSLATOR_GLOSSARY_LIMIT` 件までプロンプトに TSV 形式で添付する。
- 応答後処理で、Markdown コードフェンス、箇条書き、番号、太字、引用符風の装飾、余計な `<tags>` を削る。
- 1行入力に対して複数行出力が返った場合は、空行を捨てて1行へ結合する。
- 原文行末に `.` / `。` がない場合、訳文行末に追加された `.` / `。` は削る。
- xTranslator が先に接続を閉じた場合の `EPIPE` / `ECONNRESET` は通常の切断として扱い、プロキシは落とさない。

短文モデルの振り分けは環境変数で変えられる。

```sh
XTRANSLATOR_SHORT_MODEL=translategemma-4B
XTRANSLATOR_LONG_MODEL=translategemma-12B
XTRANSLATOR_SHORT_MODEL_MAX_LINES=2
XTRANSLATOR_SHORT_MODEL_MAX_CHARS=160
```

## xTranslator API settings

OpenAI API tab:

```txt
OpenAI_Key=no-key
OpenAI_URL=http://127.0.0.1:18080/v1/chat/completions
OpenAI_Model=translategemma-12B
OpenAI_Query=Translate to %lang_dest%. Output only the translated text:
```

Quality-first array settings are in `Misc/ApiTranslator.txt`, not `UserPrefs/commonApiPrefs.ini`.

```txt
OpenAI_CharLimit=2000
OpenAI_ArrayLimit=2
OpenAI_ArrayTimePause=0
```

After changing `Misc/ApiTranslator.txt`, restart xTranslator.

## xTranslator launcher

Use this wrapper instead of typing Wine locale vars every time:

```sh
xtranslator &
```

Wrapper:

```sh
~/.local/bin/xtranslator
```

It sets:

```sh
LANG=ja_JP.UTF-8
LC_CTYPE=ja_JP.UTF-8
```

## llama.cpp notes

`/etc/conf.d/llama.cpp` should not force these globally:

```txt
--ctx-size 0
--n-gpu-layers all
```

Set model-specific values in `/etc/llama.cpp/models.ini`.

Example:

```ini
[translategemma-12B]
model = /home/onoue/.local/lib/llama.cpp/models/translategemma-12b-it.i1-Q4_K_M.gguf
ctx-size = 1024
parallel = 1
n-gpu-layers = 30
```

If 12B fails with CUDA OOM, lower `n-gpu-layers` first.
