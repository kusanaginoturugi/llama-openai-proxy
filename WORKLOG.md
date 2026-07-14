# Work Log

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
