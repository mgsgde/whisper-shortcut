#!/bin/bash

echo "🧪 Running WhisperShortcut Tests..."
echo ""

# Parse command line arguments
INTEGRATION_TESTS=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --integration)
      INTEGRATION_TESTS=true
      shift
      ;;
    -i)
      INTEGRATION_TESTS=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--integration|-i]"
      echo "  --integration, -i: Run integration tests (requires OPENAI_API_KEY)"
      exit 1
      ;;
  esac
done

# Clean previous builds
echo "🧹 Cleaning previous builds..."
cd WhisperShortcut && \
swift package clean

if [ "$INTEGRATION_TESTS" = true ]; then
  echo "🔨 Building and running ALL tests (including integration)..."
  echo "💡 Integration tests will use API key from 'test-config' file or OPENAI_API_KEY env var"
  swift test
else
  echo "🔨 Building and running UNIT tests only..."
  echo "💡 To run integration tests: ./test.sh --integration"
  # Run only unit tests (exclude integration tests)
  swift test --filter "TranscriptionServiceTests|ClipboardManagerTests"
fi && \
cd ..

# Check if tests passed
if [ $? -eq 0 ]; then
    echo ""
    if [ "$INTEGRATION_TESTS" = true ]; then
        echo "✅ All tests (unit + integration) passed!"
    else
        echo "✅ Unit tests passed!"
        echo "💡 Run './test.sh --integration' to test with real API calls"
    fi
else
    echo ""
    echo "❌ Some tests failed. Check output above for details."
    exit 1
fi