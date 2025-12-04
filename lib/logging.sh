#!/bin/bash

# Shared logging library for pg_backctl
# Provides consistent JSON logging across all scripts

# Global variables that scripts can set:
# - LOG_FILE: Path to log file (optional, for file logging)
# - SCRIPT_NAME: Name of the calling script (for logging context)

# Escape JSON strings - pure bash implementation for performance
json_escape() {
  local string="$1"
  # Escape in order: backslashes first (to avoid double-escaping), then quotes, then control chars
  string="${string//\\/\\\\}"      # \ -> \\
  string="${string//\"/\\\"}"      # " -> \"
  string="${string//$'\n'/\\n}"    # newline -> \n
  string="${string//$'\r'/\\r}"    # carriage return -> \r
  string="${string//$'\t'/\\t}"    # tab -> \t
  echo "$string"
}

# Main JSON logging function
# Usage: log_json "LEVEL" "message" ["key1=value1" "key2=value2" ...]
# Outputs JSON to stdout and optionally to LOG_FILE
log_json() {
  local level="$1"
  local message="$2"
  shift 2

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')

  # Escape mandatory fields
  local level_escaped=$(json_escape "$level")
  local message_escaped=$(json_escape "$message")

  # Start building JSON
  local json="{\"level\":\"$level_escaped\",\"log\":\"$message_escaped\",\"timestamp\":\"$timestamp\""

  # Add script name if available
  if [ -n "${SCRIPT_NAME:-}" ]; then
    local script_escaped=$(json_escape "$SCRIPT_NAME")
    json="$json,\"script\":\"$script_escaped\""
  fi

  # Parse additional fields (key=value pairs)
  while [ $# -gt 0 ]; do
    local key="${1%%=*}"
    local value="${1#*=}"

    # Skip empty keys
    if [ -n "$key" ]; then
      local key_escaped=$(json_escape "$key")
      local value_escaped=$(json_escape "$value")
      json="$json,\"$key_escaped\":\"$value_escaped\""
    fi
    shift
  done

  # Close JSON object
  json="$json}"

  # Output to stdout (for container logs)
  echo "$json"

  # Also write to log file if configured
  if [ -n "${LOG_FILE:-}" ]; then
    echo "$json" >> "$LOG_FILE"
  fi
}

# Standard logging function (wrapper for log_json)
# Usage: log "message" ["key1=value1" "key2=value2" ...]
# Auto-detects level from message prefixes (ERROR:, WARNING:)
log() {
  local msg="$1"
  shift

  # Determine log level from message prefix
  local level="INFO"
  local clean_msg="$msg"

  if [[ "$msg" =~ ^ERROR:\ * ]]; then
    level="ERROR"
    clean_msg="${msg#ERROR: }"
  elif [[ "$msg" =~ ^WARNING:\ * ]]; then
    level="WARN"
    clean_msg="${msg#WARNING: }"
  fi

  # Call log_json with remaining arguments
  log_json "$level" "$clean_msg" "$@"
}

# Simple logging function (alias to log_json for backward compatibility)
# Usage: log_simple "message" ["key1=value1" ...]
log_simple() {
  log_json "INFO" "$@"
}

# Error function - logs error and exits
# Usage: die "error message" [exit_code]
# Requires error_codes.sh to be sourced for ERR_UNKNOWN
die() {
  local msg="$1"
  local code="${2:-${ERR_UNKNOWN:-99}}"

  # Log error with exit code
  log_json "ERROR" "$msg" "error_code=$code"

  exit "$code"
}
