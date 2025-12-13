#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🚀 WhisperShortcut Release Helper${NC}"
echo "=================================="

# 1. Check for uncommitted changes
if [[ -n $(git status -s) ]]; then
    echo -e "${RED}❌ Error: You have uncommitted changes.${NC}"
    echo "Please commit or stash your changes before creating a release."
    git status
    exit 1
fi

# 2. Get current version from Info.plist
PLIST_PATH="WhisperShortcut/Info.plist"
if [ ! -f "$PLIST_PATH" ]; then
    echo -e "${RED}❌ Error: Could not find $PLIST_PATH${NC}"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH")

echo -e "Current App Version: ${GREEN}$VERSION${NC} (Build $BUILD)"

# 3. Suggest tag name
DEFAULT_TAG="v$VERSION"
read -p "Enter tag name for release [${DEFAULT_TAG}]: " INPUT_TAG
TAG_NAME=${INPUT_TAG:-$DEFAULT_TAG}

# 4. Check if tag already exists
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo -e "${RED}❌ Error: Tag $TAG_NAME already exists.${NC}"
    exit 1
fi

# 5. Confirm
echo ""
echo -e "Ready to create release:"
echo -e "  Tag: ${GREEN}$TAG_NAME${NC}"
echo -e "  Commit: $(git rev-parse --short HEAD)"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# 6. Create and push tag
echo -e "\n${YELLOW}Creating tag...${NC}"
git tag "$TAG_NAME"

echo -e "${YELLOW}Pushing tag to origin...${NC}"
git push origin "$TAG_NAME"

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}✅ Success! Release triggered.${NC}"
    echo "Monitor the build here: https://github.com/mgsgde/whisper-shortcut/actions"
else
    echo -e "\n${RED}❌ Failed to push tag.${NC}"
    # Cleanup local tag if push failed
    git tag -d "$TAG_NAME"
    exit 1
fi
