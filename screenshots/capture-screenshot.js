#!/usr/bin/env node

/**
 * Screenshot Capture Script for WhisperShortcut App Store Images
 * 
 * This script captures a screenshot of the index.html file with 1280x800 resolution
 * for use in App Store listings.
 * 
 * Usage: node capture-screenshot.js
 * Output: app-screenshot.png in the screenshots directory
 */

const puppeteer = require('puppeteer');
const path = require('path');

async function captureScreenshot() {
  console.log('🖼️  Starting screenshot capture...');
  
  const browser = await puppeteer.launch();
  const page = await browser.newPage();
  
  // Set viewport to 1280x800 (App Store screenshot resolution)
  await page.setViewport({ width: 1280, height: 800 });
  
  // Load the HTML file
  const htmlPath = path.join(__dirname, 'index.html');
  await page.goto(`file://${htmlPath}`);
  
  // Wait for content to load
  console.log('⏳ Waiting for content to load...');
  await new Promise(resolve => setTimeout(resolve, 1000));
  
  // Take screenshot
  const outputPath = path.join(__dirname, 'app-screenshot.png');
  await page.screenshot({ 
    path: outputPath,
    fullPage: false
  });
  
  await browser.close();
  console.log(`✅ Screenshot saved as: ${outputPath}`);
  console.log('📱 Ready for App Store submission!');
}

// Run the script
captureScreenshot().catch(error => {
  console.error('❌ Error capturing screenshot:', error);
  process.exit(1);
});
