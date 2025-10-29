#!/bin/bash

# Docker utilities for pg_backctl
# Provides wrappers for common Docker and Docker Compose operations

# Wrapper functions for docker compose commands
# These require compose_filepath and service to be set

# Execute command in container
# Usage: compose_exec [command] [args...]
compose_exec() {
  docker compose -f "$compose_filepath" exec -T "$service" "$@"
}

# Copy files from/to container
# Usage: compose_cp [source] [dest]
compose_cp() {
  docker compose -f "$compose_filepath" cp "$@"
}

# Start service
# Usage: compose_up
compose_up() {
  docker compose -f "$compose_filepath" up -d "$service"
}

# Stop service
# Usage: compose_down
compose_down() {
  docker compose -f "$compose_filepath" down "$service"
}

# Restart service
# Usage: compose_restart
compose_restart() {
  docker compose -f "$compose_filepath" restart "$service"
}

# Get compose network name
# Usage: network_name=$(get_compose_network)
get_compose_network() {
  local folder_name
  folder_name=$(basename "$(dirname "$compose_filepath")")
  echo "${folder_name}_default"
}

# Get full Docker volume name from compose volume name
# Usage: full_volume=$(get_full_volume_name "postgres-data")
get_full_volume_name() {
  local volume_name="$1"
  local folder_name
  folder_name=$(basename "$(dirname "$compose_filepath")")
  echo "${folder_name}_${volume_name}"
}

# Check if Docker daemon is running
# Usage: check_docker_running
check_docker_running() {
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is not running or not accessible" $ERR_MISSING_CMD
  fi
}

# Check if required commands are available
# Usage: check_required_commands "cmd1" "cmd2" "cmd3"
check_required_commands() {
  local missing_commands=()

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done

  if [ ${#missing_commands[@]} -gt 0 ]; then
    die "Required command(s) not found in PATH: ${missing_commands[*]}. Please install before running this script." $ERR_MISSING_CMD
  fi
}
