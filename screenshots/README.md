# App Store screenshot generation

Templates and scripts to generate App Store screenshots. The app website is hosted separately (Next.js); this folder only contains the image generation tool.

**Prerequisites:** Node.js, Chrome (Puppeteer uses `/Applications/Google Chrome.app` on macOS).

```bash
npm install
npm run capture                    # Generate all screenshots
npm run capture-speech-to-text    # Or a single one
npm run capture-speech-to-prompt
npm run capture-powered-by-gemini
npm run capture-powered-by-whisper
npm run capture-open-source
npm run capture-star-history
```

**Preview templates:** `npm run preview` → http://localhost:8080/

| Folder   | Purpose |
|----------|--------|
| `html/`  | HTML templates for each App Store screenshot |
| `assets/`| Manually captured UI assets (dropdown, settings, etc.) used in templates |
| `js/capture-all.js` | Puppeteer script; writes PNGs to `images/` |
| `images/` | Generated screenshots (and logo); use these in App Store listing or the separate website |

Update `assets/` when the app UI changes, then re-run `npm run capture`.
