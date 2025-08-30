#!/usr/bin/env node

/**
 * Screenshot Capture Script for WhisperShortcut Customizable Settings
 * 
 * This script captures a screenshot of the customizable-settings.html file with 1280x800 resolution
 * for use in App Store listings.
 * 
 * Usage: node capture-customizable-settings.js
 * Output: customizable-settings.png in the screenshots directory
 */

const puppeteer = require('puppeteer');

async function captureScreenshot() {
  console.log('🖼️  Starting customizable settings screenshot capture...');
  
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
    await page.goto('file://' + __dirname + '/customizable-settings.html');
    
    // Wait for content to load
    console.log('⏳ Waiting for content to load...');
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Take screenshot
    await page.screenshot({ 
      path: 'customizable-settings.png',
      fullPage: false
    });
    
    console.log('✅ Screenshot saved as: customizable-settings.png');
  } catch (error) {
    console.error('❌ Error capturing screenshot:', error);
  } finally {
    await browser.close();
  }
}

// Run the script
captureScreenshot();
