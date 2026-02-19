---
name: rebuild-after-change
description: After any code change to the application, rebuild and restart it using the project's bash script. Use when editing Swift/source files, adding features, or fixing bugs in WhisperShortcut so the user can test changes immediately.
---

# Rebuild After Change

## Rule

**After every code change**, rebuild and restart the app so the user can test immediately.

## What to run

From the project root:

```bash
bash scripts/rebuild-and-restart.sh
```

- Run this **after** edits are done (not before).
- If you made multiple edits in one turn, run it **once** at the end.
- Do **not** skip the rebuild because the change "seems small"; the user expects a running app with the latest code.

## When to apply

- After modifying any Swift or project source file.
- After changing resources, config, or project settings that affect the build.
- When the user asks to implement something, fix a bug, or refactor—finish with a rebuild unless they say otherwise.

## When to skip

- Only when the user explicitly says not to rebuild, or when the change is to docs/scripts that don’t affect the app binary (e.g. README, plan files).
