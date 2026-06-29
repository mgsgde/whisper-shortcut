---
name: release
description: Cut a new App Store / GitHub release — bump version, write release notes, rebuild, commit, push, and tag. Use when the user asks to release, ship, or publish a new version.
---

# Release

Cut a new App Store / GitHub release: bump version, write App Store + GitHub release notes, rebuild, commit, push, tag.

## Task

1. **Run tests**: Execute the full test suite; abort the release if any test fails
2. **Bump version**: Increment CFBundleShortVersionString in `WhisperShortcut/Info.plist`
3. **Bump bundle version**: Increment CFBundleVersion in `WhisperShortcut/Info.plist`
4. **Create GitHub changelog**: Summarize changes since the previous git tag
5. **App Store "What's New in This Version" text**: User-facing changes since the last version **live on App Store Connect** (often cumulative across several GitHub releases). **Must be written in English.**
6. **Create release notes**: Detailed release notes with all changes for GitHub Release
7. **GitHub release**: Rebuild, commit only the release changes, push the current branch, then create and push a git tag to trigger the release workflow

## App Store vs GitHub baselines

**Two different “since” versions — do not conflate them:**

| Output | Baseline | Typical command |
|--------|----------|-----------------|
| `.github/RELEASE_NOTES.md` + compare link | Previous **git tag** (incremental GitHub release) | `git log v<PREV>..v<CURRENT>` |
| App Store **“What's New in This Version”** | Last version **live on App Store Connect** | `git log v<APP_STORE_LIVE>..v<CURRENT>` |

GitHub and App Store ship on different cadences. The live App Store version is often **behind** the latest GitHub tag.

**Before writing App Store text:**

1. Determine the live App Store version — ask the user if unknown (App Store Connect → sidebar “Ready for Distribution”, or a screenshot).
2. Aggregate **user-facing** changes from `v<APP_STORE_LIVE>..v<CURRENT>` (read intervening `.github/RELEASE_NOTES.md` at each tag if helpful).
3. If the build submitted to App Store is an older tag than `CURRENT`, scope App Store text to `v<APP_STORE_LIVE>..v<SUBMITTED>` instead.
4. Omit dev-only changes (test scripts, internal refactors).

**In the release output, always deliver both:**

- **GitHub release notes** — incremental since previous tag.
- **App Store “What's New”** — cumulative since last **live** App Store version (copy-paste-ready for App Store Connect).

## Steps

1. **Run all tests** with `bash scripts/run-tests.sh` — **stop immediately** if the command fails; do not bump versions, commit, or tag
2. Read `WhisperShortcut/Info.plist` and determine current versions
3. **Get repository URL**: Extract git remote URL from `git remote get-url origin` and convert from SSH format (`git@github.com:user/repo.git`) to HTTPS format (`https://github.com/user/repo`)
4. Increment versions by 1 and save `WhisperShortcut/Info.plist`
5. Analyze git log since last "update to version" commit / previous git tag
6. **GitHub release notes:** summarize changes since the previous git tag (`git log` since last `Update to version` commit / `v<PREV>`).
7. **App Store “What's New”:** summarize **user-facing** changes since the last version **live on App Store Connect** (see [App Store vs GitHub baselines](#app-store-vs-github-baselines) — not the previous git tag unless they match). Ask the user for the live App Store version when it is not stated.
8. Save GitHub release notes to `.github/RELEASE_NOTES.md` (used automatically by the workflow) – **IMPORTANT**: Use the resolved repository URL for all links (releases link and changelog link); never use placeholders like `your-repo`
9. Rebuild and start the app with `bash scripts/rebuild-and-restart.sh`; stop if the build fails
10. Git add and commit only the files changed for this release command, with message `Update to version X.X` – **Important**: `WhisperShortcut/Info.plist` and `.github/RELEASE_NOTES.md` must be included in the commit
11. Detect the current branch with `git branch --show-current`
12. Push the current branch with `git push origin <current-branch>`
13. Create git tag (format: `v<Version>`, e.g. `v7.51`) on the release commit
14. Push the tag with `git push origin <tag>`

> **Note:** `scripts/create-release.sh` is an *interactive* human helper that does only the read-version → tag → push portion (with confirmation prompts). This command runs the full release flow non-interactively (bump, notes, commit, rebuild, tag), so it creates and pushes the tag directly rather than calling that script.

## Output

- New version (e.g. "7.51")
- New bundle version (e.g. "149")
- **App Store baseline used** (e.g. “7.68 live on App Store; cumulative notes through 7.73”)
- App Store "What's New in This Version" text — cumulative since that baseline, copy-paste-ready for App Store Connect (English; 1–3 short bullets or 1–2 sentences unless the gap spans many releases)
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

This command + the `release.yml` workflow build and ship only the **notarized Developer-ID DMG** (GitHub Release). They do **not** upload to the Mac App Store. App Store submission (Xcode: Product → Archive → Distribute → Review) is a separate step and can be automated with `asc publish appstore --platform MAC_OS` — see the `app-store-connect` skill's "Submit a version for review" section. (App Store signing uses an *Apple Distribution* cert, distinct from the Developer-ID cert CI uses for the DMG.)

**Release notes format:**

Release notes should be formatted in Markdown and may include:

- Installation instructions (with link to releases page: `https://github.com/USER/REPO/releases`)
- Changes (main section)
- Full changelog link (format: `https://github.com/USER/REPO/compare/vPREVIOUS...vCURRENT`)

**IMPORTANT – Repository URL:**

- The repository URL must be obtained from `git remote get-url origin`
- SSH format (`git@github.com:user/repo.git`) must be converted to HTTPS format (`https://github.com/user/repo`)
- **NEVER** use placeholders like `your-repo` or `USER/REPO` in release notes
- The URL must be used for both links: releases link and changelog link

**Tip:** Release notes should be user-friendly and translate technical details into clear language.
