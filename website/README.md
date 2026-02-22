# WhisperShortcut website

This folder contains the **public app website** (homepage, privacy policy, terms of service, screenshots) and the **App Store screenshot generation** tooling. The site is intended for GitHub Pages or a custom domain (e.g. app homepage). Project documentation (Markdown) lives in the repo’s `docs/` folder.

## Preview the website

```bash
npm install
npm run preview
```

Then open http://localhost:8000/

## Generate screenshots

Screenshot templates and the Puppeteer capture script live in `screenshots/`. Generated PNGs are written to `images/` (same files the website uses).

**Prerequisites:** Node.js, Chrome (Puppeteer uses `/Applications/Google Chrome.app` on macOS).

```bash
npm install
npm run capture                    # Generate all screenshots
npm run capture-speech-to-text     # Generate one
npm run capture-speech-to-prompt
npm run capture-powered-by-gemini
npm run capture-powered-by-whisper
npm run capture-open-source
npm run capture-star-history
```

**Preview screenshot templates only:** `npm run preview:screenshots` → http://localhost:8080/ (serves the `screenshots/` folder).

### Screenshot layout

| Folder | Purpose |
|--------|---------|
| `screenshots/html/` | HTML templates for each App Store screenshot |
| `screenshots/assets/` | Manually captured UI assets (dropdown, settings, etc.) used in templates |
| `screenshots/js/capture-all.js` | Puppeteer script; outputs to `images/` |
| `images/` | Logo + generated screenshots (used by the website) |

Update `screenshots/assets/` when the app UI changes, then re-run `npm run capture`.
