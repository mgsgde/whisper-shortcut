---
name: push-after-rebuild
description: When the user wants to push, commit, or "save to git", first rebuild the app and only proceed with commit and push if the build succeeds. Use when the user says push, commit and push, or deploy changes to git.
---

# Push Only After Rebuild

**Before any commit or push: rebuild first** (follow the always-applied rebuild rule in `.cursor/rules/index.mdc`). If the build fails, stop — inform the user and do **not** commit or push.

## Flow

1. **Rebuild.** Fails → stop. Succeeds → continue.
2. **Commit** (only if this chat made changes). Stage **only the files you edited in this conversation** — never `git add -A`, so work from other chats/sessions stays out. Exception: the user explicitly asks to "commit everything".
   ```bash
   git status
   git add <file1> <file2> ...
   git commit -m "..."
   ```
3. **Push** (`git push`). For a release, push the branch first, then the release tag.

Commit-only requests (no push) and push-only requests (nothing new to commit) still rebuild first.
