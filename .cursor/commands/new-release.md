# Update Version Command

## Task

1. **Bump version**: Increment CFBundleShortVersionString in Info.plist by 1
2. **Bump bundle version**: Increment CFBundleVersion in Info.plist by 1
3. **Create changelog**: Summarize changes since the last "update to version" commit
4. **App Store description**: 1–3 short bullet points or 1–2 sentences for App Store
5. **Create release notes**: Detailed release notes with all changes for GitHub Release
6. **GitHub release**: Create and push git tag to trigger pipeline (release is created automatically using release notes from `.github/RELEASE_NOTES.md`)

## Steps

1. Read Info.plist and determine current versions
2. **Get repository URL**: Extract git remote URL from `git remote get-url origin` and convert from SSH format (`git@github.com:user/repo.git`) to HTTPS format (`https://github.com/user/repo`)
3. Increment versions by 1 and save
4. Analyze git log since last "update to version" commit
5. Turn changes into App Store–formatted description (1–3 short bullet points)
6. Create release notes (more detailed than App Store description, with all changes for GitHub Release) – **IMPORTANT**: Use the resolved repository URL for all links (releases link and changelog link); never use placeholders like `your-repo`
7. Save release notes to `.github/RELEASE_NOTES.md` (used automatically by the workflow)
8. Rebuild and start the app
9. Git add and commit with "Update to version X.X" (commit message in English, same as App Store description in 1–3 bullet points) – **Important**: `.github/RELEASE_NOTES.md` must be included in the commit
10. Create git tag (format: `v<Version>`, e.g. `v1.2.3`)
11. Run git push (`git push origin main` and `git push origin <tag>`)

## Output

- New version (e.g. "1.2.3")
- New bundle version (e.g. "123")
- App Store description (1–3 short bullet points)
- Release notes (detailed list of all changes for GitHub Release)
- Confirmation of created tag and push

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
