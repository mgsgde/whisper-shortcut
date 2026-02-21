# Screenshot generation (App Store)

Templates and scripts to generate App Store screenshots. Run from the **website** folder:

```bash
cd ..   # to website/
npm run capture
```

- **html/** – HTML templates per screenshot (speech-to-text, speech-to-prompt, etc.)
- **assets/** – Manually provided UI screenshots (dropdown, settings, etc.); update when the app UI changes
- **js/capture-all.js** – Puppeteer script; writes PNGs to `website/images/`

See the main [website README](../README.md) for full usage.
