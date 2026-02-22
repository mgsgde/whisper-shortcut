#!/usr/bin/env node

/**
 * Unified Screenshot Capture Script for WhisperShortcut
 * 
 * This script captures screenshots for the App Store listing
 * 
 * Usage: 
 *   node capture-all.js                    # Capture all screenshots
 *   node capture-all.js speech-to-text     # Capture specific screenshot
 *   node capture-all.js speech-to-prompt   # Capture specific screenshot
 *   node capture-all.js powered-by-gemini  # Capture specific screenshot
 *   node capture-all.js powered-by-whisper # Capture specific screenshot
 *   node capture-all.js open-source        # Capture specific screenshot
 *   node capture-all.js star-history       # Capture specific screenshot
 */

const puppeteer = require('puppeteer');
const path = require('path');
const fs = require('fs');

const screenshots = [
  {
    name: 'speech-to-text',
    html: 'speech-to-text.html',
    output: 'speech-to-text.png'
  },
  {
    name: 'speech-to-prompt', 
    html: 'speech-to-prompt.html',
    output: 'speech-to-prompt.png'
  },
  {
    name: 'powered-by-gemini',
    html: 'powered-by-gemini.html', 
    output: 'powered-by-gemini.png'
  },
  {
    name: 'powered-by-whisper',
    html: 'powered-by-whisper.html',
    output: 'powered-by-whisper.png'
  },
  {
    name: 'open-source',
    html: 'open-source.html',
    output: 'open-source.png'
  },
  {
    name: 'star-history',
    html: 'star-history.html',
    output: 'star-history.png'
  }
];

async function captureScreenshot(config) {
  console.log(`🖼️  Capturing ${config.name} screenshot...`);
  
  let browser;
  try {
    browser = await puppeteer.launch({
      headless: "new",
      executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--disable-web-security',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding'
      ]
    });

    const page = await browser.newPage();
    
    // Set viewport
    await page.setViewport({ 
      width: 1280, 
      height: 800 
    });
    
    // Load HTML file
    const htmlPath = path.join(__dirname, '..', 'html', config.html);
    const fileUrl = 'file://' + htmlPath;
    
    console.log(`📄 Loading: ${htmlPath}`);
    await page.goto(fileUrl, { 
      waitUntil: 'domcontentloaded',
      timeout: 10000 
    });

    // Star-history loads an external image from api.star-history.com; wait for it to load
    if (config.name === 'star-history') {
      try {
        await page.waitForSelector('img[src*="api.star-history.com"]', { timeout: 15000 });
        await page.evaluate(() => {
          return new Promise((resolve, reject) => {
            const img = document.querySelector('img[src*="api.star-history.com"]');
            if (!img) return reject(new Error('Chart image not found'));
            if (img.complete && img.naturalWidth > 0) return resolve();
            img.onload = () => resolve();
            img.onerror = () => reject(new Error('Chart image failed to load'));
            setTimeout(() => (img.naturalWidth > 0 ? resolve() : reject(new Error('Chart image load timeout'))), 12000);
          });
        });
      } catch (e) {
        console.warn(`⚠️  star-history: chart image may not have loaded (${e.message}), capturing anyway`);
      }
    }

    // Wait for content
    await new Promise(resolve => setTimeout(resolve, config.name === 'star-history' ? 1000 : 2000));
    
    // Take screenshot (write to website/images/ so the site uses the same files)
    const outputPath = path.join(__dirname, '..', '..', 'images', config.output);
    await page.screenshot({ 
      path: outputPath,
      fullPage: false,
      type: 'png'
    });
    
    console.log(`✅ Saved: ${outputPath}`);
    return true;
    
  } catch (error) {
    console.error(`❌ Error capturing ${config.name}:`, error.message);
    return false;
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

async function main() {
  // Check if a specific screenshot was requested
  const requestedScreenshot = process.argv[2];
  
  let screenshotsToCapture = screenshots;
  if (requestedScreenshot) {
    const found = screenshots.find(s => s.name === requestedScreenshot);
    if (!found) {
      console.error(`❌ Unknown screenshot: ${requestedScreenshot}`);
      console.error(`Available options: ${screenshots.map(s => s.name).join(', ')}`);
      process.exit(1);
    }
    screenshotsToCapture = [found];
    console.log(`🎯 Capturing specific screenshot: ${requestedScreenshot}`);
  } else {
    console.log('🚀 Starting screenshot generation for all screenshots...');
  }
  
  let successCount = 0;
  for (const config of screenshotsToCapture) {
    const success = await captureScreenshot(config);
    if (success) successCount++;
    
    // Small delay between captures
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  
  console.log(`\n📊 Results: ${successCount}/${screenshotsToCapture.length} screenshots generated successfully`);
  
  if (successCount === screenshotsToCapture.length) {
    console.log('🎉 Screenshot generation completed successfully!');
  } else {
    console.log('⚠️  Some screenshots failed to generate');
    process.exit(1);
  }
}

// Run with proper error handling
main().catch(error => {
  console.error('❌ Fatal error:', error);
  process.exit(1);
});
