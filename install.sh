#!/bin/bash

# WhisperShortcut Installation Script
# This script builds the app and installs it to /Applications

set -e  # Exit on any error

echo "🎙️ WhisperShortcut Installation Script"
echo "======================================"

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This script only works on macOS"
    exit 1
fi

# Check if Xcode command line tools are installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Error: Xcode command line tools not found"
    echo "Please install Xcode from the App Store or run: xcode-select --install"
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "WhisperShortcut.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: Please run this script from the WhisperShortcut directory"
    exit 1
fi

echo "📦 Building WhisperShortcut..."

# Clean any previous builds
echo "🧹 Cleaning previous builds..."
xcodebuild clean -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release

# Build the app
echo "🔨 Building app..."
xcodebuild build -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release -derivedDataPath build

# Check if build was successful
if [ ! -d "build/Build/Products/Release/WhisperShortcut.app" ]; then
    echo "❌ Error: Build failed. Please check the error messages above."
    exit 1
fi

echo "✅ Build successful!"

# Install to Applications
echo "📱 Installing to Applications..."
APP_PATH="build/Build/Products/Release/WhisperShortcut.app"
APPLICATIONS_PATH="/Applications/WhisperShortcut.app"

# Remove existing installation if it exists
if [ -d "$APPLICATIONS_PATH" ]; then
    echo "🗑️ Removing existing installation..."
    sudo rm -rf "$APPLICATIONS_PATH"
fi

# Copy to Applications
echo "📋 Copying app to Applications..."
sudo cp -R "$APP_PATH" "/Applications/"

# Set proper permissions
echo "🔐 Setting permissions..."
sudo chown -R root:wheel "$APPLICATIONS_PATH"
sudo chmod -R 755 "$APPLICATIONS_PATH"

echo ""
echo "🎉 Installation complete!"
echo "========================="
echo "WhisperShortcut has been installed to /Applications/"
echo ""
echo "Next steps:"
echo "1. Open WhisperShortcut from Applications"
echo "2. Right-click the menu bar icon and select 'Settings...'"
echo "3. Enter your Google Gemini API key"
echo "4. Start recording with ⌘⌥R"
echo ""
echo "Enjoy using WhisperShortcut! 🎙️"
