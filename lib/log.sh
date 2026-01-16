#!/bin/bash
# log.sh - Logging utilities

LOG_LEVEL="${LOG_LEVEL:-info}"

# ANSI colors
_RED='\033[0;31m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_GRAY='\033[0;90m'
_NC='\033[0m' # No Color

_log() {
    local level="$1"
    local color="$2"
    shift 2
    echo -e "${color}[$(date -Iseconds)] [${level}]${_NC} $*" >&2
}

log_debug() {
    [[ "${LOG_LEVEL}" == "debug" ]] && _log "DEBUG" "${_GRAY}" "$@"
    return 0
}

log_info() {
    _log "INFO" "${_BLUE}" "$@"
}

log_warn() {
    _log "WARN" "${_YELLOW}" "$@"
}

log_error() {
    _log "ERROR" "${_RED}" "$@"
}