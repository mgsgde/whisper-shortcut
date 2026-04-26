# Implementation Plans

This directory is the shared source of truth for implementation plans and specs used by Cursor, Claude, and other coding agents.

## Structure

- `active/` contains plans that are currently being implemented or still expected to guide future work.
- `archive/` contains completed or superseded plans that may still be useful as context.
- `templates/` contains reusable plan formats.

## Guidelines

- Keep plans in plain Markdown so every tool can read and edit them.
- Prefer one plan per feature, bug, workflow, or release task.
- Move completed plans from `active/` to `archive/` instead of deleting them when they contain useful decision history.
- Do not duplicate plans under `.cursor/` or `.claude/`; agent-specific files should only point here.
- Before implementing a plan, read the relevant file in `plans/active/` and update it if requirements have changed.
