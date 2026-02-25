#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared constants, logging, traps, and lockfile
# Source this first in every top-level script.
# =============================================================================

# Version
readonly VERSION="1.0.0"

# ---------- resolve project root ----------
# Works whether sourced from the repo root or from lib/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
readonly SCRIPT_DIR
readonly PROJECT_ROOT="${SCRIPT_DIR%/lib}"

# ---------- colors (each on its own line for grep-ability) ----------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ---------- logging ----------
# Log directory — default ~/.local/log/astroneer-vps, overridable via .env
LOG_DIR="${LOG_DIR:-$HOME/.local/log/astroneer-vps}"
_LOG_FILE=""

_init_logging() {
    mkdir -p "$LOG_DIR"
    _LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"

    # Rotate: keep last 5 log files
    local count
    count=$(find "$LOG_DIR" -maxdepth 1 -name '*.log' -type f 2>/dev/null | wc -l)
    if [[ "$count" -gt 5 ]]; then
        # shellcheck disable=SC2012
        ls -1t "$LOG_DIR"/*.log | tail -n +"6" | xargs rm -f 2>/dev/null || true
    fi
}

_log() {
    local msg="$1"
    if [[ -n "$_LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$_LOG_FILE"
    fi
}

info() {
    echo -e "${CYAN}==> $*${NC}"
    _log "INFO  $*"
}

ok() {
    echo -e "${GREEN}  ✓ $*${NC}"
    _log "OK    $*"
}

warn() {
    echo -e "${YELLOW}  ⚠ $*${NC}" >&2
    _log "WARN  $*"
}

fail() {
    echo -e "${RED}  ✗ $*${NC}" >&2
    _log "FAIL  $*"
    exit 1
}

# ---------- dry-run support ----------
DRY_RUN=false

# Execute a command, or print it if --dry-run is active.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${DIM}[dry-run] $*${NC}"
        _log "DRY   $*"
    else
        "$@"
    fi
}

# ---------- timeouts (named constants) ----------
readonly SSH_TIMEOUT_DEFAULT=120
readonly SSH_TIMEOUT_START=180
readonly SHUTDOWN_TIMEOUT=60
readonly SETUP_SSH_TIMEOUT=1800
readonly SETUP_SSH_INTERVAL=15
readonly LOG_TAIL_DEFAULT=50

# ---------- lockfile ----------
readonly LOCK_FILE="/tmp/astroneer-vps.lock"
LOCK_FD=""

acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        fail "Another astroneer-vps process is running (lockfile: $LOCK_FILE)"
    fi
}

release_lock() {
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi
}

# ---------- cleanup trap ----------
# Scripts can append to _CLEANUP_COMMANDS before or after sourcing.
_CLEANUP_COMMANDS=()

register_cleanup() {
    _CLEANUP_COMMANDS+=("$@")
}

_cleanup() {
    local exit_code=$?
    # Run registered cleanup commands in reverse order
    local i
    for (( i=${#_CLEANUP_COMMANDS[@]}-1; i>=0; i-- )); do
        eval "${_CLEANUP_COMMANDS[$i]}" 2>/dev/null || true
    done
    release_lock
    exit "$exit_code"
}

trap _cleanup EXIT INT TERM

# ---------- init ----------
_init_logging
