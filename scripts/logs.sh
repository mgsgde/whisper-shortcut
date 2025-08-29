#!/bin/bash

# WhisperShortcut Log Streaming Script
# Usage: ./scripts/logs.sh [options]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
PROCESS_NAME="WhisperShortcut"
LOG_STYLE="compact"
FILTER=""
TIME_RANGE=""

# Function to show usage
show_usage() {
    echo -e "${CYAN}WhisperShortcut Log Streaming Script${NC}"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -p, --process NAME      Process name to filter (default: WhisperShortcut)"
    echo "  -s, --style STYLE       Log style: compact, detailed, json (default: compact)"
    echo "  -f, --filter PATTERN    Filter logs by pattern (e.g., 'PROMPT-MODE')"
    echo "  -t, --time RANGE        Time range: 1h, 30m, 1d (default: real-time)"
    echo "  -v, --verbose           Verbose output"
    echo ""
    echo "Examples:"
echo "  $0                                    # Stream all WhisperShortcut logs"
echo "  $0 -f 'PROMPT-MODE'                   # Only prompt mode logs"
echo "  $0 -f 'TRANSCRIPTION-MODE'            # Only transcription logs"
echo "  $0 -f 'VOICE-RESPONSE-MODE'           # Only voice response logs"
echo "  $0 -f 'Error'                         # Only error logs"
echo "  $0 -t 1h                              # Show logs from last hour"
echo "  $0 -s detailed                        # Detailed log format"
echo "  $0 -f 'PROMPT-MODE' -s json           # JSON format for prompt mode"
echo ""
echo "Log Categories:"
echo "  🤖 PROMPT-MODE:        Prompt execution and processing"
echo "  🎙️ TRANSCRIPTION-MODE: Audio transcription process"
echo "  🔊 VOICE-RESPONSE-MODE: Voice response and TTS processing"
echo "  ⚠️ Errors:             Error handling and recovery"
echo "  🎹 Shortcuts:          Keyboard shortcut registration"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -p|--process)
            PROCESS_NAME="$2"
            shift 2
            ;;
        -s|--style)
            LOG_STYLE="$2"
            shift 2
            ;;
        -f|--filter)
            FILTER="$2"
            shift 2
            ;;
        -t|--time)
            TIME_RANGE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Validate log style
case $LOG_STYLE in
    compact|detailed|json)
        ;;
    *)
        echo -e "${RED}Invalid log style: $LOG_STYLE${NC}"
        echo "Valid styles: compact, detailed, json"
        exit 1
        ;;
esac

# Build the log command
LOG_CMD="log stream --predicate 'process == \"$PROCESS_NAME\"' --style $LOG_STYLE"

# Add filter if specified
if [[ -n "$FILTER" ]]; then
    LOG_CMD="$LOG_CMD --predicate 'process == \"$PROCESS_NAME\" AND eventMessage CONTAINS \"$FILTER\"'"
fi

# Show configuration
echo -e "${GREEN}🔍 Starting WhisperShortcut Log Stream${NC}"
echo -e "${BLUE}Process:${NC} $PROCESS_NAME"
echo -e "${BLUE}Style:${NC} $LOG_STYLE"
if [[ -n "$FILTER" ]]; then
    echo -e "${BLUE}Filter:${NC} $FILTER"
fi
if [[ -n "$TIME_RANGE" ]]; then
    echo -e "${BLUE}Time Range:${NC} $TIME_RANGE"
fi
echo -e "${BLUE}Command:${NC} $LOG_CMD"
echo ""

# Check if process is running
if ! pgrep -f "$PROCESS_NAME" > /dev/null; then
    echo -e "${YELLOW}⚠️  Warning: $PROCESS_NAME is not currently running${NC}"
    echo -e "${YELLOW}   Start the app first to see logs${NC}"
    echo ""
fi

# Show helpful tips
echo -e "${CYAN}💡 Tips:${NC}"
echo -e "  • Press Ctrl+C to stop logging"
echo -e "  • Use -f 'PROMPT-MODE' to debug prompt issues"
echo -e "  • Use -f 'TRANSCRIPTION-MODE' to debug transcription issues"
echo -e "  • Use -f 'VOICE-RESPONSE-MODE' to debug voice response issues"
echo -e "  • Use -f 'Error' to see only error messages"
echo ""

# Execute the log command
echo -e "${GREEN}📋 Starting log stream...${NC}"
echo ""

if [[ -n "$TIME_RANGE" ]]; then
    # Show historical logs
    log show --predicate "process == \"$PROCESS_NAME\"" --last "$TIME_RANGE" --style "$LOG_STYLE"
else
    # Stream real-time logs
    eval "$LOG_CMD"
fi
