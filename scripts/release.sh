#!/bin/bash

# WhisperShortcut Release Script
# This script helps create GitHub releases for WhisperShortcut
#
# Usage: ./scripts/release.sh [release-notes-file]
#   - release-notes-file: Path to markdown file containing release notes (optional)
#   - If no file is provided, the script will create a template and open it for editing

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [release-notes-file]"
    echo ""
    echo "Options:"
    echo "  release-notes-file    Path to markdown file containing release notes"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Create template and edit interactively"
    echo "  $0 RELEASE_NOTES_v1.1.md             # Use existing release notes file"
    echo "  $0 scripts/release_template.md       # Use template file directly"
    echo ""
    echo "If no file is provided, the script will:"
    echo "  1. Create a release notes template"
    echo "  2. Open it in your default editor"
    echo "  3. Continue with the release process"
}

# Check if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script only works on macOS"
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "WhisperShortcut.xcodeproj/project.pbxproj" ]; then
    print_error "Please run this script from the WhisperShortcut directory"
    exit 1
fi

# Check if required tools are installed
if ! command -v xcodebuild &> /dev/null; then
    print_error "Xcode command line tools not found"
    echo "Please install Xcode from the App Store or run: xcode-select --install"
    exit 1
fi

if ! command -v git &> /dev/null; then
    print_error "Git not found"
    exit 1
fi

# Get current version from project
CURRENT_VERSION=$(grep -A1 'MARKETING_VERSION' WhisperShortcut.xcodeproj/project.pbxproj | grep -o '[0-9]\+\.[0-9]\+' | head -1)
CURRENT_BUILD=$(grep -A1 'CURRENT_PROJECT_VERSION' WhisperShortcut.xcodeproj/project.pbxproj | grep -o '[0-9]\+' | head -1)

print_info "Current version: $CURRENT_VERSION (Build $CURRENT_BUILD)"

# Check if we have uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    print_warning "You have uncommitted changes. Please commit or stash them before creating a release."
    git status --short
    echo ""
    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get release version
echo ""
read -p "Enter release version (e.g., 1.2.0) [current: $CURRENT_VERSION]: " RELEASE_VERSION
RELEASE_VERSION=${RELEASE_VERSION:-$CURRENT_VERSION}

# Handle release notes file
RELEASE_NOTES_FILE="$1"

if [ -n "$RELEASE_NOTES_FILE" ]; then
    # User provided a release notes file
    if [ ! -f "$RELEASE_NOTES_FILE" ]; then
        print_error "Release notes file not found: $RELEASE_NOTES_FILE"
        exit 1
    fi
    
    print_status "Using release notes file: $RELEASE_NOTES_FILE"
    
    # Read the file and replace placeholders
    TEMP_NOTES=$(mktemp)
    cp "$RELEASE_NOTES_FILE" "$TEMP_NOTES"
    
    # Replace placeholders if they exist
    sed -i '' "s/{{VERSION}}/$RELEASE_VERSION/g" "$TEMP_NOTES" 2>/dev/null || true
    sed -i '' "s/{{DATE}}/$(date +"%B %Y")/g" "$TEMP_NOTES" 2>/dev/null || true
    sed -i '' "s/{{BUILD}}/$CURRENT_BUILD/g" "$TEMP_NOTES" 2>/dev/null || true
    
else
    # No file provided, create template
    echo ""
    print_info "Creating release notes template..."
    
    # Create temporary file for release notes
    TEMP_NOTES=$(mktemp)
    
    # Check if template file exists
    TEMPLATE_FILE="scripts/release_template.md"
    if [ -f "$TEMPLATE_FILE" ]; then
        # Copy template and replace placeholders
        cp "$TEMPLATE_FILE" "$TEMP_NOTES"
        
        # Replace placeholders with actual values (macOS compatible)
        sed -i '' "s/{{VERSION}}/$RELEASE_VERSION/g" "$TEMP_NOTES"
        sed -i '' "s/{{DATE}}/$(date +"%B %Y")/g" "$TEMP_NOTES"
        sed -i '' "s/{{BUILD}}/$CURRENT_BUILD/g" "$TEMP_NOTES"
    else
        # Fallback template if template file doesn't exist
        cat > "$TEMP_NOTES" << EOF
# WhisperShortcut $RELEASE_VERSION

**Release Date:** $(date +"%B %Y")  
**Build:** $CURRENT_BUILD  
**macOS:** 15.5+  
**Minimum Xcode:** 16.0+

## 🎉 What's New

- 

## 🐛 Bug Fixes

- 

## 🔧 Technical Details

- Build: $CURRENT_BUILD
- macOS: 15.5+
EOF
    fi
    
    # Open editor for release notes
    print_info "Opening release notes for editing..."
    if command -v cursor &> /dev/null; then
        cursor --wait "$TEMP_NOTES"
    elif command -v nano &> /dev/null; then
        nano "$TEMP_NOTES"
    elif command -v vim &> /dev/null; then
        vim "$TEMP_NOTES"
    else
        print_warning "No suitable editor found. Please edit the release notes manually."
        echo "Release notes file: $TEMP_NOTES"
        read -p "Press Enter when you're done editing..."
    fi
fi

# Read release notes
RELEASE_NOTES=$(cat "$TEMP_NOTES")
rm "$TEMP_NOTES"

# Confirm release
echo ""
echo "=== Release Summary ==="
echo "Version: $RELEASE_VERSION"
echo "Build: $CURRENT_BUILD"
echo ""
echo "Release Notes:"
echo "$RELEASE_NOTES"
echo ""
read -p "Do you want to proceed with creating this release? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Release cancelled"
    exit 1
fi

# Build the app
print_status "Building WhisperShortcut..."
xcodebuild clean -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release
xcodebuild build -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release -derivedDataPath build

# Check if build was successful
if [ ! -d "build/Build/Products/Release/WhisperShortcut.app" ]; then
    print_error "Build failed. Please check the error messages above."
    exit 1
fi

print_status "Build successful!"

# Create release directory
RELEASE_DIR="release"
mkdir -p "$RELEASE_DIR"

# Copy app to release directory
APP_PATH="build/Build/Products/Release/WhisperShortcut.app"
RELEASE_APP_PATH="$RELEASE_DIR/WhisperShortcut.app"

if [ -d "$RELEASE_APP_PATH" ]; then
    rm -rf "$RELEASE_APP_PATH"
fi

cp -R "$APP_PATH" "$RELEASE_APP_PATH"

# Create zip file
ZIP_NAME="WhisperShortcut-$RELEASE_VERSION.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

print_status "Creating zip file..."
cd "$RELEASE_DIR"
zip -r "$ZIP_NAME" "WhisperShortcut.app"
cd ..

print_status "Release package created: $ZIP_PATH"

# Create git tag
TAG_NAME="v$RELEASE_VERSION"
print_status "Creating git tag: $TAG_NAME"

# Check if tag already exists
if git tag -l | grep -q "^$TAG_NAME$"; then
    print_warning "Tag $TAG_NAME already exists. Do you want to delete it and recreate?"
    read -p "Delete existing tag? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git tag -d "$TAG_NAME"
        git push origin ":refs/tags/$TAG_NAME" 2>/dev/null || true
    else
        print_error "Tag already exists. Please use a different version or delete the existing tag."
        exit 1
    fi
fi

# Create and push tag
git tag -a "$TAG_NAME" -m "Release $RELEASE_VERSION"
git push origin "$TAG_NAME"

print_status "Git tag created and pushed!"

# Create GitHub release
print_info "Creating GitHub release..."

# Check if gh CLI is installed
if command -v gh &> /dev/null; then
    print_status "Using GitHub CLI to create release..."
    
    # Create release with gh CLI (publish directly, not as draft)
    gh release create "$TAG_NAME" \
        --title "WhisperShortcut $RELEASE_VERSION" \
        --notes "$RELEASE_NOTES" \
        "$ZIP_PATH"
    
    print_status "GitHub release created and published!"
    print_info "Release available at: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^/]*\/[^/]*\)\.git.*/\1/')/releases/tag/$TAG_NAME"
else
    print_warning "GitHub CLI not found. Please create the release manually:"
    echo ""
    echo "1. Go to: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^/]*\/[^/]*\)\.git.*/\1/')/releases"
    echo "2. Click 'Create a new release'"
    echo "3. Choose tag: $TAG_NAME"
    echo "4. Title: WhisperShortcut $RELEASE_VERSION"
    echo "5. Description:"
    echo "$RELEASE_NOTES"
    echo ""
    echo "6. Upload the zip file: $ZIP_PATH"
    echo "7. Publish the release"
fi

echo ""
print_status "Release process completed!"
echo ""
echo "Next steps:"
echo "1. Verify the GitHub release is published correctly"
echo "2. Update the README if needed"
echo "3. Share the release with users"
echo ""
echo "Release files:"
echo "- App: $RELEASE_APP_PATH"
echo "- Zip: $ZIP_PATH"
echo "- Tag: $TAG_NAME"
