# Release Guide

This guide explains how to create GitHub releases for WhisperShortcut.

## Quick Start (Recommended)

Use the automated release script:

```bash
./scripts/release.sh
```

This script will guide you through the entire release process automatically.

## Manual Release Process

If you prefer to create releases manually or the script doesn't work for you, follow these steps:

### 1. Prepare for Release

1. **Check current version:**

   ```bash
   # Check current version in project
   grep -A1 'MARKETING_VERSION' WhisperShortcut.xcodeproj/project.pbxproj
   grep -A1 'CURRENT_PROJECT_VERSION' WhisperShortcut.xcodeproj/project.pbxproj
   ```

2. **Ensure all changes are committed:**

   ```bash
   git status
   git add .
   git commit -m "Prepare for release v1.2.0"
   git push origin main
   ```

### 2. Build the App

1. **Clean and build:**

   ```bash
   xcodebuild clean -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release
   xcodebuild build -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release -derivedDataPath build
   ```

2. **Verify build success:**

   ```bash
   ls -la build/Build/Products/Release/WhisperShortcut.app
   ```

### 3. Create Release Package

1. **Create release directory:**

   ```bash
   mkdir -p release
   ```

2. **Copy app to release directory:**

   ```bash
   cp -R build/Build/Products/Release/WhisperShortcut.app release/
   ```

3. **Create zip file:**

   ```bash
   cd release
   zip -r WhisperShortcut-1.2.0.zip WhisperShortcut.app
   cd ..
   ```

### 4. Create Git Tag

1. **Create annotated tag:**

   ```bash
   git tag -a v1.2.0 -m "Release 1.2.0"
   ```

2. **Push tag to GitHub:**

   ```bash
   git push origin v1.2.0
   ```

### 5. Create GitHub Release

1. **Go to GitHub releases page:**
   - Navigate to: `https://github.com/yourusername/whisper-shortcut/releases`

2. **Create new release:**
   - Click "Create a new release"
   - Choose the tag you just created (e.g., `v1.2.0`)

3. **Fill in release details:**
   - **Title:** `WhisperShortcut 1.2.0`
   - **Description:** Add release notes (see template below)
   - **Attach:** Upload the zip file from `release/WhisperShortcut-1.2.0.zip`

4. **Publish release:**
   - Click "Publish release"

## Release Notes Template

Use this template for release notes:

```markdown
# WhisperShortcut 1.2.0

## What's New

- ✨ New feature: [Description]
- 🎨 UI improvements: [Description]
- 🔧 Performance improvements: [Description]

## Bug Fixes

- 🐛 Fixed: [Description of bug fix]
- 🐛 Fixed: [Description of bug fix]

## Technical Details

- Build: 10
- macOS: 15.5+
- Minimum Xcode: 16.0+

## Installation

1. Download `WhisperShortcut-1.2.0.zip` from this release
2. Extract the zip file
3. Drag `WhisperShortcut.app` to your Applications folder
4. Launch the app and configure your OpenAI API key

## Support

- GitHub Issues: [Link to issues]
- Documentation: [Link to docs]
```

## Version Numbering

Follow semantic versioning (SemVer):

- **MAJOR.MINOR.PATCH** (e.g., 1.2.0)
  - **MAJOR:** Breaking changes
  - **MINOR:** New features (backward compatible)
  - **PATCH:** Bug fixes (backward compatible)

## Pre-release Checklist

Before creating a release, ensure:

- [ ] All tests pass: `./scripts/test.sh`
- [ ] App builds successfully in Release configuration
- [ ] Version numbers are updated in project
- [ ] Release notes are prepared
- [ ] All changes are committed and pushed
- [ ] App has been tested on target macOS version

## Troubleshooting

### Build Issues

If the build fails:

1. **Clean build artifacts:**

   ```bash
   rm -rf build DerivedData
   ```

2. **Check Xcode version:**

   ```bash
   xcodebuild -version
   ```

3. **Verify scheme exists:**

   ```bash
   xcodebuild -list -project WhisperShortcut.xcodeproj
   ```

### Tag Issues

If tag creation fails:

1. **Check if tag exists:**

   ```bash
   git tag -l | grep v1.2.0
   ```

2. **Delete existing tag (if needed):**

   ```bash
   git tag -d v1.2.0
   git push origin :refs/tags/v1.2.0
   ```

### GitHub CLI Issues

If GitHub CLI isn't working:

1. **Install GitHub CLI:**

   ```bash
   # macOS
   brew install gh
   
   # Or download from: https://cli.github.com/
   ```

2. **Authenticate:**

   ```bash
   gh auth login
   ```

## Support

If you encounter issues with the release process:

1. Check the [GitHub Issues](https://github.com/yourusername/whisper-shortcut/issues)
2. Review the [Development Documentation](README.md#development)
3. Ensure you're following the [Prerequisites](README.md#prerequisites)
