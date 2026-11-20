## Read Aloud
- OpenAI retires its text-to-speech models on January 6, 2027. Read Aloud now offers GPT-Realtime 2.1 mini, OpenAI's named replacement. If you used the old OpenAI voice and have an OpenAI key, Read Aloud switches to the new model on its own.

## Offline models
- Clicking Download on an offline model whose files are already on your Mac (from Hugging Face or LM Studio) now offers to import them instead of downloading them again.

## Dictate Prompt
- A reply that is mostly the model's own reasoning or far too long is no longer pasted. Your selection stays unchanged and you can try again.
- With local models, an instruction that was not understood is rejected before the model runs, and a short instruction that closely matches one of your saved prompts uses that prompt.

## Chat
- Ask the Chat why a result came out wrong and it checks your recent results and configuration, then either names the setting that caused it with a fix, or suggests sending a report with `/feedback`.

## Report a Problem
- Reports for a Dictate Prompt result now show whether text around the cursor and earlier turns were sent.

## Under the hood
- The usage log records, per Dictate Prompt result, how much text around the cursor and how many earlier turns were sent.
- Unused code removed and shared helpers merged.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v9.04...v9.05
