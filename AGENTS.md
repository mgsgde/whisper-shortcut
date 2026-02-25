# AGENTS.md

## Cursor Cloud specific instructions

### Platform constraint

WhisperShortcut is a **native macOS application** (Swift / Xcode). The main app **cannot be built or run** on the Linux-based Cursor Cloud VM — it requires macOS 15.5+ with Xcode 16.0+. All build/rebuild commands (`bash scripts/rebuild-and-restart.sh`, `install.sh`, `xcodebuild`) will fail on Linux.

Code editing, reviewing Swift files, and working with documentation are fully supported on the Cloud VM.

### What CAN run on the Cloud VM

- **Website** (`website/`): Static site served via `npm run preview` (port 8000). Install deps with `npm install` in the `website/` directory.
- **Screenshot generation** (`npm run capture` in `website/`): Requires Puppeteer/Chrome — works on the VM but screenshots reference macOS UI assets.

### Running the website

```bash
cd website
npm install
npm run preview  # serves on http://localhost:8000
```

### Build and test commands (macOS only)

See `CLAUDE.md` and `README.md` for the canonical build/test workflow. Key commands (all require macOS + Xcode):

- Build & restart: `bash scripts/rebuild-and-restart.sh`
- Stream logs: `bash scripts/logs.sh`
- Tests: run manually in Xcode (no CLI test runner)

### No automated linting or CLI tests

This project has no SwiftLint config, no ESLint config, and no automated test suite runnable from CLI. Tests are executed manually in Xcode per project conventions.
