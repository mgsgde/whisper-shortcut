# Implementation Plans

This directory is the shared source of truth for implementation plans and specs used by Cursor, Claude, and other coding agents.

## Guidelines

- One plan per feature, bug, workflow, or release task. Keep plans in plain Markdown so every tool can read and edit them.
- Add plan files directly under `plans/`. Delete them once the work is done — git history preserves decision context if you ever need it.
- Do not duplicate plans under `.cursor/` or `.claude/`; agent-specific files should only point here.
- Before implementing a plan, read the relevant file and update it if requirements have changed.
