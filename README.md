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

## xTranslator API settings

OpenAI API tab:

```txt
OpenAI_Key=no-key
OpenAI_URL=http://127.0.0.1:18080/v1/chat/completions
OpenAI_Model=translategemma-12B
OpenAI_Query=Translate the following text from the video game Skyrim to %lang_dest%. Preserve the exact text structure, line breaks, <tags>, placeholders, proper names, and numbers. Use natural fantasy RPG / Skyrim terminology. Do not add explanations, notes, quotes, Markdown, or extra lines. Output only the translated text:
```

Quality-first array settings are in `Misc/ApiTranslator.txt`, not `UserPrefs/commonApiPrefs.ini`.

```txt
OpenAI_CharLimit=1000
OpenAI_ArrayLimit=1
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
