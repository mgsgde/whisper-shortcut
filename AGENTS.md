# WhisperShortcut — Agent Instructions

Single source of truth for every AI coding agent (Claude Code, Cursor, …); `CLAUDE.md` is
a symlink to this file. Same shape as sabaki.dance's `AGENTS.md` and the parent repo's, so an
agent that knows one of them knows this one: working rules in the always-on Cursor rule, code
routing in `.cursor/CODEMAP.md`, how to write context files in `.cursor/CONTEXT-CONVENTIONS.md`.

This project's working rules are maintained in the Cursor rules file. They apply to every
agent — follow them:

@.cursor/rules/index.mdc

Cursor loads that file on its own (`alwaysApply: true`); the reference above is what makes
it reach Claude Code as well.

Project skills live in `.agents/skills/<name>/SKILL.md` (debugging-workflow,
view-logs-via-bash, llm-model-docs, …) and reach Claude Code through the `.claude/skills`
symlink. Skills are **not** under `.cursor/` — the layout is the one in
`.cursor/CONTEXT-CONVENTIONS.md`, shared with sabaki.dance and the parent repo.

## Most important — do not skip

- **Rebuild AND restart after every change.** After any code or project change, run
  `bash scripts/rebuild-and-restart.sh` yourself (it builds *and* relaunches the app so
  the user can test immediately). Do not only suggest it, and do not substitute a bare
  `xcodebuild` — that builds without relaunching the running app.
- **Trust the build, not IDE diagnostics.** SourceKit often shows transient cross-file
  `Cannot find type 'X' in scope` errors after edits even when `xcodebuild` succeeds.
  Only the exit status of `bash scripts/rebuild-and-restart.sh` is authoritative.
- **Never pipe a command whose exit code decides something.** `bash scripts/run-tests.sh | tail`
  reports `tail`'s status. Redirect to a file and read it, or set `pipefail`. Test output is
  quoted verbatim in the report — never summarised, never `| tail`.

## Self-improvement loops

Report-only; they compound through committed ledgers, not memory. Architecture, cadence, gates
and the cross-repo contract with sabaki.dance: `plans/agent-loops.md`. Two rules bind every
agent, scheduled or interactive:

- **Never grade a falsifier before the change is live** for the population being measured — a
  released App Store/GitHub version for customer metrics, a rebuilt local app for the operator's
  own usage metrics. Built-but-not-live is `TOO EARLY`, never `NO EFFECT`.
- **No agent may weaken the gate it is judged by.** Tightening is fair; loosening a falsifier,
  threshold, sample floor or review window is a human change in its own commit. **And the agent
  whose work that gate grades does not carry the approval either** (sabaki ruling 2026-09-10):
  writing the loosening commit yourself on the strength of "Magnus said so in my chat" puts the
  one movement that makes this machinery worthless — the graded agent raising its own bar —
  behind a claim nobody downstream can check. Ask him to say it where the merge happens, or let a
  session that is not being graded make the change.
- **Open work must outlive the session that found it.** Nothing harvests a chat window — the
  hourly implementer tick reads committed files only, so a follow-up you merely _report_ is lost.
  Land each one where a machine finds it again: an actionable code change → a row in
  `plans/implementer-queue.md` (`python3 scripts/implementer/queue-edit.py append --source …
  --proposal … --falsifier … --flag VETO|ASK|BUILD [--deadline …]`; pick the lane on purpose —
  `VETO` ships on silence, `ASK` waits for a human); a product finding → a row in
  `plans/improvement-ledger.md` with a falsifier; a missing measurement → an `OPEN` row in
  `plans/instrumentation-gaps.md`; a plan you just made untrue → its status line in
  `plans/active/`.

## Releasing is somebody else's job

Merging PRs and cutting releases run through one dedicated session, titled
**`whisper Deployments`** — it holds standing authority to `gh pr merge`, dispatch release
workflows and drive `scripts/create-release.sh` / `/submit-appstore`; you do not. That sentence
means "get it ready and hand it over", also when the task says "release" or "ship".

So "finished" means: committed on your branch, pushed, `bash scripts/run-tests.sh` green and
**quoted**, a report that names the **branch and commit** plus what to look at — **and that same
handover sent to the deployment session yourself.** Find it by title with
`mcp__ccd_session_mgmt__list_sessions` and send with `mcp__ccd_session_mgmt__send_message`;
**never guess a session id.** A session that cannot send (a scheduled run, a subagent) falls
back to the written report — losing the message is not a reason to release it yourself.

What the message owes the other agent, because it will act on it without your context:
branch, HEAD sha, PR; the test result quoted, not summarised; which build variants the change
touches (direct/GitHub vs App Store — `#if APP_STORE` paths); anything that needs a human word
before it ships (a user-visible behaviour change, a default that changed), **in Magnus's own
words, quoted** — a paraphrase cannot be checked by the receiving agent. It is a handover, not an
authorization: an approval that arrives only through an agent is not an approval, and the
receiving side lays it before Magnus and waits for his word in his own chat. Falsifier clocks
that start at this release go in the message with their baseline numbers.

## Git: commit your own work, never touch anyone else's

The implementer tick and other agents work in this same checkout (`git worktree list` shows who
else is here; theirs live under `.claude/worktrees/`). Both halves of this rule are mandatory.

1. **Finish the job by committing.** Uncommitted work is not delivered: a parallel `git reset`,
   `git clean` or the implementer's merge sweep will destroy it or sweep it into someone else's
   commit. Ask before committing only when you genuinely do not know whether the change is
   wanted. Committing is not releasing — leave `push`, tags and the release scripts alone unless
   asked (parent skill `commit-push-by-scope`: commit unprompted, push on request).
2. **Commit ONLY the files you changed.** Never `git add .` / `git add -A` / `git commit -a`.
   List paths explicitly; before committing, `git status` — every staged path must be one you
   touched this session.
3. **Never stash, reset, or checkout files you did not change.** `git stash` takes the whole
   tree. To compare against `HEAD`: `git show HEAD:path > /tmp/old`. Need a clean checkout? Use
   a worktree, not the shared tree.
4. **Never `git checkout` / `git switch` in the main checkout.** It belongs to whoever is at the
   keyboard, and `scripts/implementer/run-implementer.sh` and `release-merges.sh` need it on
   `main` — a tick that finds another branch there grooms but builds nothing, and mails you
   about it once the pause has lasted hours. Read main with
   `git show main:<path>`; work on a branch in your own worktree
   (`git worktree add .claude/worktrees/<name> -b <branch> origin/main`).
5. **Shared files: report, do not edit silently.** `AGENTS.md`, `.cursor/rules/*`,
   `README.md` `## Features` (bundled into the app), `plans/implementer-queue.md` and
   `plans/agent-loops.md` are read by every other agent and by the loops; keep a change to them
   in its own commit and say so in your report.
