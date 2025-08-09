#!/bin/bash

# WhisperShortcut Test Runner Script
# This script runs the Xcode tests for the WhisperShortcut project

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "WhisperShortcut.xcodeproj/project.pbxproj" ]; then
    print_error "WhisperShortcut.xcodeproj not found. Please run this script from the project root directory."
    exit 1
fi

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    print_error "xcodebuild not found. Please install Xcode from the App Store."
    exit 1
fi

# Parse command line arguments
VERBOSE=false
CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose    Run tests with verbose output"
            echo "  -c, --clean      Clean DerivedData before running tests"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0               Run tests normally"
            echo "  $0 -v            Run tests with verbose output"
            echo "  $0 -c            Clean and run tests"
            echo "  $0 -v -c         Clean and run tests with verbose output"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Clean DerivedData if requested
if [ "$CLEAN" = true ]; then
    print_status "Cleaning DerivedData..."
    rm -rf DerivedData
    print_success "DerivedData cleaned"
fi

# Remove existing test results to avoid conflicts
if [ -e "./TestResults.xcresult" ]; then
    print_status "Removing existing test results..."
    rm -rf ./TestResults.xcresult
fi

# Build the test command with the working configuration
TEST_CMD="xcodebuild test -scheme WhisperShortcut -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData -resultBundlePath ./TestResults.xcresult -only-testing:WhisperShortcutTests"

if [ "$VERBOSE" = true ]; then
    TEST_CMD="$TEST_CMD -verbose"
fi

print_status "Running tests..."
print_status "Command: $TEST_CMD"
echo ""

# Run the tests
if eval $TEST_CMD 2>&1 | tee /tmp/test_output.log; then
    echo ""
    print_success "All tests passed! 🎉"
    print_status "Test results saved to: ./TestResults.xcresult"
    print_status "DerivedData location: ./DerivedData"
elif grep -q "TEST SUCCEEDED" /tmp/test_output.log; then
    echo ""
    print_success "All tests passed! 🎉"
    print_warning "Note: Tests completed successfully despite early exit warning"
    print_status "Test results saved to: ./TestResults.xcresult"
    print_status "DerivedData location: ./DerivedData"
else
    echo ""
    print_error "Tests failed! ❌"
    print_status "Check the output above for details."
    print_status "Test results saved to: ./TestResults.xcresult"
    print_status "DerivedData location: ./DerivedData"
    exit 1
fi
