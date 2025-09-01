# WhisperShortcut Screenshots

This directory contains all the assets and scripts needed to generate App Store screenshots for WhisperShortcut.

## Directory Structure

```
screenshots/
├── html/                    # HTML files for each screenshot
│   ├── speech-to-text.html
│   ├── speech-to-prompt.html
│   └── powered-by-openai.html
├── images/                  # Generated PNG screenshots
│   ├── speech-to-text.png
│   ├── speech-to-prompt.png
│   ├── powered-by-openai.png
│   ├── dropdown.png
│   └── settings.png
├── js/                     # JavaScript capture scripts
│   ├── capture-speech-to-text.js
│   ├── capture-speech-to-prompt.js
│   └── capture-powered-by-openai.js
├── package.json            # Node.js dependencies
└── README.md              # This file
```

## Screenshot Descriptions

### 1. Speech-to-Text
- **File**: `html/speech-to-text.html`
- **Script**: `js/capture-speech-to-text.js`
- **Output**: `images/speech-to-text.png`
- **Content**: Shows the core transcription functionality with step-by-step process

### 2. Speech-to-Prompt
- **File**: `html/speech-to-prompt.html`
- **Script**: `js/capture-speech-to-prompt.js`
- **Output**: `images/speech-to-prompt.png`
- **Content**: Shows the AI prompt generation feature with voice input and response

### 3. Powered by OpenAI
- **File**: `html/powered-by-openai.html`
- **Script**: `js/capture-powered-by-openai.js`
- **Output**: `images/powered-by-openai.png`
- **Content**: Shows the OpenAI integration and advanced settings configuration

## Usage

### Prerequisites
- Node.js installed
- Dependencies installed: `npm install`

### Generate All Screenshots
```bash
cd js
node capture-speech-to-text.js
node capture-speech-to-prompt.js
node capture-powered-by-openai.js
```

### Generate Specific Screenshot
```bash
cd js
node capture-speech-to-text.js      # For speech-to-text
node capture-speech-to-prompt.js    # For speech-to-prompt
node capture-powered-by-openai.js   # For OpenAI settings
```

## Technical Details

- **Resolution**: All screenshots are generated at 1280x800 pixels
- **Format**: PNG with transparency support
- **Browser**: Uses Puppeteer (headless Chrome) for consistent rendering
- **Styling**: Modern gradient design with Apple-style typography

## File Naming Convention

- **HTML files**: Descriptive names (e.g., `speech-to-text.html`)
- **JavaScript files**: `capture-{feature-name}.js`
- **Output images**: `{feature-name}.png`
- **Supporting images**: Descriptive names (e.g., `dropdown.png`, `settings.png`)

## Maintenance

When adding new screenshots:
1. Create HTML file in `html/` directory
2. Create capture script in `js/` directory
3. Update this README with new screenshot description
4. Test the capture script to ensure it works correctly
