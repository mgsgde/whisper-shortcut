const puppeteer = require('puppeteer');

async function captureScreenshot() {
  console.log('🖼️  Starting prompt screenshot capture...');
  
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
    await page.goto('file://' + __dirname + '/prompt-screenshot.html');
    
    // Wait for content to load
    console.log('⏳ Waiting for content to load...');
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Take screenshot
    await page.screenshot({ 
      path: 'prompt-screenshot.png',
      fullPage: false
    });
    
    console.log('✅ Prompt screenshot saved as: prompt-screenshot.png');
  } catch (error) {
    console.error('❌ Error capturing screenshot:', error);
  } finally {
    await browser.close();
  }
}

// Run the script
captureScreenshot();
