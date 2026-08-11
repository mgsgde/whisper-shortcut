# WhisperShortcut — Agent Instructions

Single source of truth for every AI coding agent (Claude Code, Cursor, …); `CLAUDE.md` is
a symlink to this file.

This project's working rules are maintained in the Cursor rules file. They apply to every
agent — follow them:

@.cursor/rules/index.mdc

Cursor loads that file on its own (`alwaysApply: true`); the reference above is what makes
it reach Claude Code as well.

The `.cursor/skills/` directory also holds project skills (debugging-workflow,
view-logs-via-bash, llm-model-docs, …); they reach Claude Code through the
`.claude/skills` symlink.

## Most important — do not skip

- **Rebuild AND restart after every change.** After any code or project change, run
  `bash scripts/rebuild-and-restart.sh` yourself (it builds *and* relaunches the app so
  the user can test immediately). Do not only suggest it, and do not substitute a bare
  `xcodebuild` — that builds without relaunching the running app.
- **Trust the build, not IDE diagnostics.** SourceKit often shows transient cross-file
  `Cannot find type 'X' in scope` errors after edits even when `xcodebuild` succeeds.
  Only the exit status of `bash scripts/rebuild-and-restart.sh` is authoritative.
