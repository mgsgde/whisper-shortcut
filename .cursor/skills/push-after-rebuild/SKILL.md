---
name: push-after-rebuild
description: When the user wants to push, commit, or "save to git", first rebuild the app and only proceed with commit and push if the build succeeds. Use when the user says push, commit and push, or deploy changes to git.
---

# Push Only After Rebuild

## Rule

**Before every push:** Build first and verify everything works. Only then commit and push.

## Flow (always in this order)

1. **Rebuild**  
   From project root:
   ```bash
   bash scripts/rebuild-and-restart.sh
   ```
   - If the build **fails**: Stop. Inform the user and do **not** commit or push.
   - If the build **succeeds**: Proceed to step 2.

2. **Commit** (only if there are changes)  
   ```bash
   git status
   ```
   - If there is nothing to commit: Optionally do step 3 only (push), if there are already commits to push.
   - If there are changes: Choose a meaningful commit message, then:
   ```bash
   git add -A
   git commit -m "..."
   ```

3. **Push**  
   ```bash
   git push
   ```

## When to apply

- User says e.g. "push", "commit and push", "push changes", "deploy to git".
- User wants to send changes to the remote repo – then always rebuild first.

## When to skip

- User wants to commit only without push → still rebuild first, then only commit (no push).
- User wants to push only with no new changes (already committed) → only `git push`; rebuild optional but recommended if code was changed recently.

## Summary

**Order:** Rebuild → (only on success) Commit (if needed) → Push. Never push without a successful build first.
