---
name: release
description: Cut a new App Store / GitHub release — bump version, write release notes, rebuild, commit, push, and tag. Use when the user asks to release, ship, or publish a new version.
---

# Release

Cut a new App Store / GitHub release: bump version, write App Store + GitHub release notes, rebuild, commit, push, tag.

The full procedure is the numbered list under [Steps](#steps) — that is the only list; follow it in
order. The App Store "What's New" text must be written in **English**.

## App Store vs GitHub baselines

**Two different “since” versions — do not conflate them:**

| Output | Baseline | Typical command |
|--------|----------|-----------------|
| `.github/RELEASE_NOTES.md` + compare link | Previous **git tag** (incremental GitHub release) | `git log v<PREV>..v<CURRENT>` |
| App Store **“What's New in This Version”** | Last version **live on App Store Connect** | `git log v<APP_STORE_LIVE>..v<CURRENT>` |

GitHub and App Store ship on different cadences. The live App Store version is often **behind** the latest GitHub tag.

**Before writing App Store text:**

1. Determine the live App Store version by following **Resolve the live App Store baseline** in the
   `app-store-connect` skill — **query it, do not ask the user.** That section owns the command and
   the state string; `/submit-appstore` reads the same baseline for `--copy-metadata-from`.
2. Aggregate **user-facing** changes from `v<APP_STORE_LIVE>..v<CURRENT>` (read intervening `.github/RELEASE_NOTES.md` at each tag if helpful).
3. If the build submitted to App Store is an older tag than `CURRENT`, scope App Store text to `v<APP_STORE_LIVE>..v<SUBMITTED>` instead.
4. Omit dev-only changes (test scripts, internal refactors).

**In the release output, always deliver both:**

- **GitHub release notes** — incremental since previous tag.
- **App Store “What's New”** — cumulative since last **live** App Store version (copy-paste-ready for App Store Connect).

## Steps

1. **Run all tests** with `bash scripts/run-tests.sh` — **stop immediately** if the command fails; do not bump versions, commit, or tag
2. **Refresh bundled docs.** Confirm `README.md` reflects every user-facing feature and shortcut added since the last release — both the `## Features` list and the shortcuts table. `README.md` is copied into the app bundle (`scripts/rebuild-and-restart.sh`) and the in-app **Chat answers "what can this app do?" questions from it** via the `read_whisper_shortcut_doc` tool. A feature missing here makes the Chat wrongly claim it does not exist — this is exactly how Voice Feedback slipped through. Skim `git log <last-tag>..HEAD` for new features/shortcuts and update README **before** bumping the version
3. Read `WhisperShortcut/Info.plist` and determine current versions
4. **Get repository URL**: Extract git remote URL from `git remote get-url origin` and convert from SSH format (`git@github.com:user/repo.git`) to HTTPS format (`https://github.com/user/repo`)
5. Increment `CFBundleShortVersionString` **and** `CFBundleVersion` by 1 and save `WhisperShortcut/Info.plist`
6. Analyze git log since last "update to version" commit / previous git tag
7. **GitHub release notes:** summarize changes since the previous git tag (`git log` since last `Update to version` commit / `v<PREV>`).
8. **App Store “What's New”:** summarize **user-facing** changes since the last version **live on App Store Connect** (see [App Store vs GitHub baselines](#app-store-vs-github-baselines) — not the previous git tag unless they match). Get the live App Store version from `asc` rather than asking.
9. Save GitHub release notes to `.github/RELEASE_NOTES.md` (used automatically by the workflow) – **IMPORTANT**: Use the resolved repository URL for all links (releases link and changelog link); never use placeholders like `your-repo`
10. Rebuild and start the app with `bash scripts/rebuild-and-restart.sh`; stop if the build fails
11. Git add and commit only the files changed for this release command, with message `Update to version X.X` – **Important**: `WhisperShortcut/Info.plist` and `.github/RELEASE_NOTES.md` must be included in the commit
12. Detect the current branch with `git branch --show-current`
13. Push the current branch with `git push origin <current-branch>`
14. **Create and push the tag with the script — do not run `git tag` / `git push` by hand:**

    ```bash
    bash scripts/create-release.sh --tag "v<Version>" --yes --skip-tests --allow-dirty
    ```

    Each flag is deliberate: `--yes` because this flow is non-interactive, `--skip-tests` because
    step 1 already ran them against this tree, `--allow-dirty` because step 11 commits only the
    release files and unrelated work may still be in the tree (the script still refuses to tag if
    `Info.plist` or `RELEASE_NOTES.md` are uncommitted). Stop if it exits non-zero.

> **Why the script and not `git tag`:** it refuses a tag that already exists, refuses a tag that
> does not match `Info.plist` (`/submit-appstore` looks the build up by `v$VERSION`, so a mismatch
> breaks App Store submission later), and deletes the local tag again if the push fails. Spelling
> the two git commands out here loses all three. `bash scripts/create-release.sh` with no arguments
> is the same script in its interactive mode, for a human cutting a release by hand.

## Output

- New version (`<PREV+1>`)
- New bundle version (`<PREV_BUNDLE+1>`)
- **App Store baseline used** (`<APP_STORE_LIVE> live on App Store; cumulative notes through <CURRENT>`) — always the value you queried from `asc`, never a remembered one
- App Store "What's New in This Version" text — cumulative since that baseline, copy-paste-ready for App Store Connect (English; 1–3 short bullets or 1–2 sentences unless the gap spans many releases). **English only** — `/submit-appstore` step 7 translates it into the other configured locales, so keep the bullets short enough to survive translation
- GitHub release notes (incremental list of changes since previous tag for `.github/RELEASE_NOTES.md`)
- Test run result (pass / fail — release aborts on fail)
- Confirmation of rebuilt app, commit, branch push, created tag, and tag push

## Release Notes Note

The GitHub Actions workflow automatically creates a release when a tag is pushed and uses the release notes from `.github/RELEASE_NOTES.md`.

**Workflow:**

1. Release notes are created in this command and saved to `.github/RELEASE_NOTES.md`
2. The file is committed with the version-update commit
3. On tag push, the workflow reads this file and uses it as the release body
4. If the file does not exist, default text is used

## Scope: GitHub release only — App Store submit is separate

This command + the `release.yml` workflow build and ship only the **notarized Developer-ID DMG** (GitHub Release). They do **not** upload to the Mac App Store. App Store submission is a separate step, automated by **`/submit-appstore`** (run it *after* `/release` cuts the matching tag). That command owns the packaging and signing rules — the `.pkg`/`.ipa` trap and the App Store certs are documented there, not here.

**Release notes format:**

Release notes should be formatted in Markdown and may include:

- **Store CTA — always the first line after the title (growth ledger G1):**
  `**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.`
  Keep the `/go/appstore?src=github-release` hop exactly as written — it is how release-note
  clicks become attributable in the Cloud Run logs (`plans/instrumentation-gaps.md` #1/#7).
- Installation instructions (with link to releases page: `https://github.com/USER/REPO/releases`)
- Changes (main section)
- Full changelog link (format: `https://github.com/USER/REPO/compare/vPREVIOUS...vCURRENT`)

**IMPORTANT – Repository URL:**

- The repository URL must be obtained from `git remote get-url origin`
- SSH format (`git@github.com:user/repo.git`) must be converted to HTTPS format (`https://github.com/user/repo`)
- **NEVER** use placeholders like `your-repo` or `USER/REPO` in release notes
- The URL must be used for both links: releases link and changelog link

**Tip:** Release notes should be user-friendly and translate technical details into clear language.
