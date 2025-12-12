#!/bin/bash

# Shared logging library for pg_backctl
# Provides consistent JSON logging across all scripts

# Global variables that scripts can set:
# - LOG_FILE: Path to log file (optional, for file logging)
# - SCRIPT_NAME: Name of the calling script (for logging context)

# Rotate log files (keep last N files)
# Usage: rotate_logs "/path/to/logfile.log" [max_rotations]
rotate_logs() {
  local log_file="$1"
  local max_rotations="${2:-5}"  # Default: keep 5 old logs
  
  # If log file doesn't exist, nothing to rotate
  [ ! -f "$log_file" ] && return 0
  
  # Remove oldest log if at limit
  local oldest="$log_file.$max_rotations"
  [ -f "$oldest" ] && rm -f "$oldest"
  
  # Rotate existing logs (from newest to oldest)
  for i in $(seq $((max_rotations - 1)) -1 1); do
    local old="$log_file.$i"
    local new="$log_file.$((i + 1))"
    [ -f "$old" ] && mv "$old" "$new"
  done
  
  # Rotate current log to .1
  [ -f "$log_file" ] && mv "$log_file" "$log_file.1"
}

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
    # Validate input contains '=' sign
    if [[ ! "$1" =~ = ]]; then
      shift
      continue  # Skip malformed input
    fi
    
    local key="${1%%=*}"
    local value="${1#*=}"

    # Skip empty keys
    if [ -n "$key" ]; then
      local key_escaped=$(json_escape "$key")

      # Auto-detect numeric values (integers and decimals)
      if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        # Numeric value - output without quotes
        json="$json,\"$key_escaped\":$value"
      else
        # String value - output with quotes and escaping
        local value_escaped=$(json_escape "$value")
        json="$json,\"$key_escaped\":\"$value_escaped\""
      fi
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
    # Fallback to original if empty after prefix removal
    [ -z "$clean_msg" ] && clean_msg="$msg"
  elif [[ "$msg" =~ ^WARNING:\ * ]]; then
    level="WARN"
    clean_msg="${msg#WARNING: }"
    # Fallback to original if empty after prefix removal
    [ -z "$clean_msg" ] && clean_msg="$msg"
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
