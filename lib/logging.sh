#!/bin/bash

# Shared logging library for pg_backctl
# Provides consistent logging across all scripts with optional JSON/nginx format support

# Global variables that scripts can set:
# - LOG_FILE: Path to log file (optional)
# - NGINX_LOG_FILE: Path to nginx-format log file for New Relic (optional)
# - SCRIPT_NAME: Name of the calling script (for logging context)

# Escape JSON strings
json_escape() {
  local string="$1"
  # Escape backslashes, quotes, and newlines
  echo "$string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

# Logging function for New Relic (nginx format)
# Usage: log_json "LEVEL" "message" "event_type" "key1=value1" "key2=value2" ...
log_json() {
  local level="$1"
  local message="$2"
  local event_type="${3:-log}"
  shift 3

  # Skip if nginx log file not configured
  if [ -z "$NGINX_LOG_FILE" ]; then
    return 0
  fi

  local timestamp_nginx=$(date '+%d/%b/%Y:%H:%M:%S %z')

  # Parse additional fields into associative array
  local -A fields
  fields["status"]="success"
  fields["backup_label"]="-"
  fields["destination"]="-"
  fields["compression"]="-"
  fields["backup_size_bytes"]="0"
  fields["duration_seconds"]="0"

  # Parse key=value pairs
  while [ $# -gt 0 ]; do
    local key="${1%%=*}"
    local value="${1#*=}"
    fields["$key"]="$value"
    shift
  done

  # Determine HTTP-style status code
  local status_code
  case "$level" in
    ERROR) status_code="500" ;;
    WARN)  status_code="400" ;;
    *)     status_code="200" ;;
  esac

  if [ "${fields[status]}" = "failed" ]; then
    status_code="500"
  fi

  # nginx combined log format:
  # $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"
  #
  # Adapted for pg_backctl:
  # $hostname - $service [$timestamp] "$event_type backup_label method" $status_code $bytes "$destination" "$user_agent"

  local request="$event_type ${fields[backup_label]} HTTP/1.1"
  local user_agent="pg_backctl/1.3.0 compression=${fields[compression]} duration=${fields[duration_seconds]}s"

  local nginx_log="$(hostname) - pg_backctl [$timestamp_nginx] \"$request\" $status_code ${fields[backup_size_bytes]} \"${fields[destination]}\" \"$user_agent\""

  echo "$nginx_log" >> "$NGINX_LOG_FILE"
}

# Standard logging function
# Usage: log "message"
# Supports prefixes: ERROR:, WARNING:
log() {
  local msg="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  local script_prefix="${SCRIPT_NAME:+[$SCRIPT_NAME] }"

  # Write to log file if configured
  if [ -n "$LOG_FILE" ]; then
    echo "[$timestamp] ${script_prefix}$msg" >> "$LOG_FILE"
  fi

  # Also echo to stdout for non-error messages
  if [[ ! "$msg" =~ ^ERROR: ]]; then
    echo "${script_prefix}$msg"
  fi

  # Determine log level for JSON logging
  local level="INFO"
  if [[ "$msg" =~ ^ERROR: ]]; then
    level="ERROR"
  elif [[ "$msg" =~ ^WARNING: ]]; then
    level="WARN"
  fi

  # Log to JSON (strip level prefix from message if present)
  local clean_msg="${msg#ERROR: }"
  clean_msg="${clean_msg#WARNING: }"
  log_json "$level" "$clean_msg" "${SCRIPT_NAME:-pg_backctl}_log"
}

# Simple logging function for entrypoint scripts
# Usage: log_simple "message"
log_simple() {
  local msg="$1"
  local script_prefix="${SCRIPT_NAME:+[$SCRIPT_NAME] }"
  echo "${script_prefix}$msg"
}

# Error function - logs error and exits
# Usage: die "error message" [exit_code]
# Requires error_codes.sh to be sourced for ERR_UNKNOWN
die() {
  local msg="$1"
  local code="${2:-${ERR_UNKNOWN:-99}}"

  # Use appropriate logging based on what's available
  if declare -f log >/dev/null 2>&1; then
    log "ERROR: $msg"
  else
    log_simple "ERROR: $msg" >&2
  fi

  # Try to log JSON if function exists
  if declare -f log_json >/dev/null 2>&1; then
    log_json "ERROR" "$msg" "error" "error_code=$code"
  fi

  echo "Error $code: $msg" >&2
  exit "$code"
}
