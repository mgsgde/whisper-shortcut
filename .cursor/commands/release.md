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
4. **Create changelog**: Summarize changes since the last "update to version" commit
5. **App Store "What's New in This Version" text**: 1–3 short bullet points or 1–2 sentences for the App Store "What's New in This Version" field. **Must be written in English.**
6. **Create release notes**: Detailed release notes with all changes for GitHub Release
7. **GitHub release**: Rebuild, commit only the release changes, push the current branch, then create and push a git tag to trigger the release workflow

## Steps

1. **Run all tests** with `bash scripts/run-tests.sh` — **stop immediately** if the command fails; do not bump versions, commit, or tag
2. Read `WhisperShortcut/Info.plist` and determine current versions
3. **Get repository URL**: Extract git remote URL from `git remote get-url origin` and convert from SSH format (`git@github.com:user/repo.git`) to HTTPS format (`https://github.com/user/repo`)
4. Increment versions by 1 and save `WhisperShortcut/Info.plist`
5. Analyze git log since last "update to version" commit
6. Turn changes into App Store "What's New in This Version" text (1–3 short bullet points, **English only** — this lands directly in the App Store's What's New field)
7. Create release notes (more detailed than App Store description, with all changes for GitHub Release) – **IMPORTANT**: Use the resolved repository URL for all links (releases link and changelog link); never use placeholders like `your-repo`
8. Save release notes to `.github/RELEASE_NOTES.md` (used automatically by the workflow)
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
- App Store "What's New in This Version" text (1–3 short bullet points, English) — copy-paste-ready for the App Store Connect "What's New in This Version" field
- Release notes (detailed list of all changes for GitHub Release)
- Test run result (pass / fail — release aborts on fail)
- Confirmation of rebuilt app, commit, branch push, created tag, and tag push

## Release Notes Note

The GitHub Actions workflow automatically creates a release when a tag is pushed and uses the release notes from `.github/RELEASE_NOTES.md`.

**Workflow:**

1. Release notes are created in this command and saved to `.github/RELEASE_NOTES.md`
2. The file is committed with the version-update commit
3. On tag push, the workflow reads this file and uses it as the release body
4. If the file does not exist, default text is used

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
