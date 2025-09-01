#!/usr/bin/env node

/**
 * Screenshot Capture Script for WhisperShortcut Speech-to-Text
 * 
 * This script captures a screenshot of the speech-to-text.html file with 1280x800 resolution
 * for use in App Store listings.
 * 
 * Usage: node capture-speech-to-text.js
 * Output: speech-to-text.png in the images directory
 */

const puppeteer = require('puppeteer');
const path = require('path');

async function captureScreenshot() {
  console.log('🖼️  Starting speech-to-text screenshot capture...');
  
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  
  try {
    const page = await browser.newPage();
    
    // Set viewport to match the original screenshot dimensions exactly
    await page.setViewport({ 
      width: 1280, 
      height: 800 
    });
    
    // Load the HTML file
    const htmlPath = path.join(__dirname, '..', 'html', 'speech-to-text.html');
    await page.goto('file://' + htmlPath);
    
    // Wait for content to load
    console.log('⏳ Waiting for content to load...');
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Take screenshot
    const outputPath = path.join(__dirname, '..', 'images', 'speech-to-text.png');
    await page.screenshot({ 
      path: outputPath,
      fullPage: false
    });
    
    console.log('✅ Screenshot saved as: ' + outputPath);
  } catch (error) {
    console.error('❌ Error capturing screenshot:', error);
  } finally {
    await browser.close();
  }
}

// Run the script
captureScreenshot();
