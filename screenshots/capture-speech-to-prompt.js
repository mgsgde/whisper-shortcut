#!/usr/bin/env node

/**
 * Screenshot Capture Script for WhisperShortcut Speech-to-Prompt
 * 
 * This script captures a screenshot of the speech-to-prompt.html file with 1280x800 resolution
 * for use in App Store listings.
 * 
 * Usage: node capture-speech-to-prompt.js
 * Output: speech-to-prompt.png in the screenshots directory
 */

const puppeteer = require('puppeteer');

async function captureScreenshot() {
  console.log('🖼️  Starting speech-to-prompt screenshot capture...');
  
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
    await page.goto('file://' + __dirname + '/speech-to-prompt.html');
    
    // Wait for content to load
    console.log('⏳ Waiting for content to load...');
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Take screenshot
    await page.screenshot({ 
      path: 'speech-to-prompt.png',
      fullPage: false
    });
    
    console.log('✅ Screenshot saved as: speech-to-prompt.png');
  } catch (error) {
    console.error('❌ Error capturing screenshot:', error);
  } finally {
    await browser.close();
  }
}

// Run the script
captureScreenshot();
