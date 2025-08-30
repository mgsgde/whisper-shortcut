#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# This script builds the project, kills any running instances, and restarts the app

set -e  # Exit on any error

echo "🔨 Building WhisperShortcut project..."
xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug build

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    
    echo "🔄 Killing any running WhisperShortcut instances..."
    pkill -f WhisperShortcut || true
    
    echo "⏳ Waiting for app to fully close..."
    sleep 1
    
    echo "🚀 Starting WhisperShortcut application..."
    open /Users/mgsgde/Library/Developer/Xcode/DerivedData/WhisperShortcut-budjpsyyuwuiqxgeultiqzrgjcos/Build/Products/Debug/WhisperShortcut.app
    
    echo "🎉 WhisperShortcut has been rebuilt and restarted!"
else
    echo "❌ Build failed! Please check the error messages above."
    exit 1
fi
