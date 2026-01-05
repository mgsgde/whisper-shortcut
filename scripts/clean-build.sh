#!/bin/bash

# WhisperShortcut Clean Build Script
# This script cleans all build artifacts to resolve build loops and corrupted cache issues

set -e  # Exit on any error

echo "🧹 Cleaning WhisperShortcut build artifacts..."

# Kill any running xcodebuild processes
echo "🛑 Stopping any running builds..."
pkill -9 xcodebuild 2>/dev/null || true
sleep 1

# Clean Xcode build
echo "🧹 Cleaning Xcode build folder..."
xcodebuild clean -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug 2>&1 | grep -E "(clean|succeeded|failed)" || true

# Remove derived data
echo "🧹 Removing derived data..."
rm -rf ~/Library/Developer/Xcode/DerivedData/WhisperShortcut-* 2>/dev/null && echo "✅ Derived data cleaned" || echo "⚠️  No derived data found"

# Remove module cache
echo "🧹 Cleaning module cache..."
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex 2>/dev/null && echo "✅ Module cache cleaned" || echo "⚠️  Module cache already clean"

# Remove Swift package checkouts (will be re-downloaded on next build)
echo "🧹 Cleaning Swift package checkouts..."
find ~/Library/Developer/Xcode/DerivedData -name "WhisperShortcut-*" -type d -exec rm -rf {}/SourcePackages \; 2>/dev/null && echo "✅ Package checkouts cleaned" || echo "⚠️  No package checkouts found"

echo ""
echo "✅ Build cleanup complete!"
echo "💡 You can now rebuild the project with: bash scripts/rebuild-and-restart.sh"

