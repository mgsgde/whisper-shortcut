# Security Policy

## Supported Versions

Security fixes are provided for the **latest release** on [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases) and for the current `main` branch. Older versions may not receive patches.

| Version | Supported |
| --- | --- |
| Latest GitHub Release / Mac App Store build | Yes |
| Older releases | Best effort |

## Reporting a Vulnerability

**Please do not open public GitHub issues for security vulnerabilities.**

Report privately using one of these channels:

1. **GitHub Security Advisories (preferred):**  
   [Create a private security advisory](https://github.com/mgsgde/whisper-shortcut/security/advisories/new)

2. **Email:**  
   [mgsgde@gmail.com](mailto:mgsgde@gmail.com?subject=WhisperShortcut%20Security%20Report)  
   Use subject line: `WhisperShortcut Security Report`

Include:

- A clear description of the issue and its impact
- Steps to reproduce
- Affected version (app build or commit SHA)
- Your macOS version, if relevant

We aim to acknowledge reports within **3 business days** and will keep you updated on fix progress. We may ask for more details before publishing a fix or advisory.

## Scope

In scope:

- The WhisperShortcut macOS app (menu bar app, local data handling, Keychain storage, OAuth flows, sandboxing)
- This repository’s source code, including build/install scripts
- Signed `.dmg` artifacts published on GitHub Releases

Out of scope:

- Vulnerabilities in third-party services (Google Gemini, OpenAI, xAI/Grok, Trello, Apple APIs) — report those to the respective provider
- Issues that require physical access to an unlocked Mac or malware already running on the user’s machine
- Social engineering or phishing against users

## Product Security Notes

- **No backend:** The app talks directly to APIs you configure with your own keys. We do not operate a telemetry or account server.
- **Secrets:** API keys and OAuth tokens are stored in the macOS Keychain, not in plain-text settings files.
- **Installation:** Prefer the **signed `.dmg` from GitHub Releases** or the **Mac App Store** build. The optional `install.sh` script in this repo only builds from source with Xcode on your machine and copies the app to `/Applications`; review it before running. It does not download remote binaries or run with elevated privileges by default.

## Recognition

We are grateful for responsible disclosure. With your permission, we can credit reporters in release notes after a fix ships.
