#!/bin/bash

# Creates and pushes a v* tag, which triggers the GitHub Actions release workflow.
#
# Two callers, one implementation:
#   - a human, interactively:  bash scripts/create-release.sh
#   - the /release command:    bash scripts/create-release.sh --tag "v7.99" --yes --skip-tests --allow-dirty
#
# The safety checks below (tag already exists, release files committed, roll the
# local tag back if the push fails) are the reason /release calls this instead of
# spelling out `git tag` / `git push` itself.

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

TAG_NAME=""
ASSUME_YES=false
SKIP_TESTS=false
ALLOW_DIRTY=false

usage() {
    cat <<'USAGE'
Usage: bash scripts/create-release.sh [options]

  --tag <name>    Tag to create (default: prompt, suggesting v<CFBundleShortVersionString>)
  --yes           Do not prompt for confirmation
  --skip-tests    Do not run scripts/run-tests.sh (only when the caller already ran them)
  --allow-dirty   Permit unrelated modified files; still requires the release files
                  (Info.plist, .github/RELEASE_NOTES.md) to be committed
  -h, --help      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)          TAG_NAME="$2"; shift 2 ;;
        --yes)          ASSUME_YES=true; shift ;;
        --skip-tests)   SKIP_TESTS=true; shift ;;
        --allow-dirty)  ALLOW_DIRTY=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo -e "${RED}❌ Unknown option: $1${NC}"; usage; exit 1 ;;
    esac
done

echo -e "${YELLOW}🚀 WhisperShortcut Release Helper${NC}"
echo "=================================="

# 1. Check the working tree.
#    Strict by default. With --allow-dirty only the files that *define* the release
#    have to be committed — /release commits those and may legitimately leave other
#    work in the tree.
RELEASE_FILES=(WhisperShortcut/Info.plist .github/RELEASE_NOTES.md)
if [ "$ALLOW_DIRTY" = true ]; then
    if ! git diff --quiet HEAD -- "${RELEASE_FILES[@]}"; then
        echo -e "${RED}❌ Error: release files have uncommitted changes.${NC}"
        echo "Commit them before tagging:"
        git status -s -- "${RELEASE_FILES[@]}"
        exit 1
    fi
elif [[ -n $(git status -s) ]]; then
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

# 3. Resolve the tag name
DEFAULT_TAG="v$VERSION"
if [ -z "$TAG_NAME" ]; then
    if [ "$ASSUME_YES" = true ]; then
        TAG_NAME="$DEFAULT_TAG"
    else
        read -p "Enter tag name for release [${DEFAULT_TAG}]: " INPUT_TAG
        TAG_NAME=${INPUT_TAG:-$DEFAULT_TAG}
    fi
fi

# 4. The tag must match Info.plist — /submit-appstore looks the build up by `v$VERSION`,
#    so a mismatch here silently breaks App Store submission later.
if [ "$TAG_NAME" != "$DEFAULT_TAG" ]; then
    if [ "$ASSUME_YES" = true ]; then
        echo -e "${RED}❌ Error: tag $TAG_NAME does not match Info.plist version ($DEFAULT_TAG).${NC}"
        exit 1
    fi
    echo -e "${YELLOW}⚠️  Warning: tag $TAG_NAME does not match Info.plist version ($DEFAULT_TAG).${NC}"
fi

# 5. Check if tag already exists
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo -e "${RED}❌ Error: Tag $TAG_NAME already exists.${NC}"
    exit 1
fi

# 6. Run tests
if [ "$SKIP_TESTS" = true ]; then
    echo -e "\n${YELLOW}Skipping tests (--skip-tests).${NC}"
else
    echo -e "\n${YELLOW}Running tests before release...${NC}"
    bash "$(dirname "$0")/run-tests.sh"
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}❌ Tests failed. Release aborted.${NC}"
        exit 1
    fi
fi

# 7. Confirm
echo ""
echo -e "Ready to create release:"
echo -e "  Tag: ${GREEN}$TAG_NAME${NC}"
echo -e "  Commit: $(git rev-parse --short HEAD)"
echo ""

if [ "$ASSUME_YES" != true ]; then
    read -p "Continue? (y/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

# 8. Create and push tag
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
