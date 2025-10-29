#!/bin/bash

# Shared INI-style configuration file parser for pg_backctl
# This library provides a generic INI parser that can be used across multiple scripts

# Parse INI configuration file
# Usage: parse_config_file <config_path> <callback_function>
#
# The callback function will be called for each key=value pair with three arguments:
#   callback_function "section_name" "key" "value"
#
# Example:
#   my_config_handler() {
#     local section="$1"
#     local key="$2"
#     local value="$3"
#
#     case "$section" in
#       database)
#         case "$key" in
#           service) service="$value" ;;
#           port) db_port="$value" ;;
#         esac
#         ;;
#     esac
#   }
#
#   parse_config_file "/path/to/config.conf" my_config_handler

parse_config_file() {
  local config_path="$1"
  local callback_function="$2"

  if [ ! -f "$config_path" ]; then
    echo "ERROR: Config file not found: $config_path" >&2
    return 1
  fi

  local current_section=""

  while IFS= read -r line || [ -n "$line" ]; do
    # Remove leading/trailing whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Check for section header
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      continue
    fi

    # Parse key=value pairs
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      # Trim whitespace from key and value
      key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Remove inline comments (everything from # to end of line)
      value=$(echo "$value" | sed 's/[[:space:]]*#.*$//')

      # Remove quotes if present
      value=$(echo "$value" | sed 's/^["'\'']\(.*\)["'\'']$/\1/')

      # Call the callback function with section, key, value
      if [ -n "$callback_function" ]; then
        "$callback_function" "$current_section" "$key" "$value"
      fi
    fi
  done < "$config_path"
}
