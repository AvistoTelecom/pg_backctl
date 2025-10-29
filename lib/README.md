# pg_backctl Shared Libraries

This directory contains shared utility libraries used across multiple pg_backctl scripts.

## Libraries

### config_parser.sh
- **Purpose**: Parse INI-style configuration files
- **Key Functions**:
  - `parse_config_file(config_path, callback_function)` - Parse config and call callback for each key/value
- **Features**:
  - Handles sections `[section_name]`
  - Supports inline comments (strips `# comment` from values)
  - Removes quotes from values
  - Trims whitespace

### error_codes.sh
- **Purpose**: Centralized error code definitions
- **Error Codes**:
  - `ERR_MISSING_CMD=10` - Required command not found
  - `ERR_MISSING_ENV=11` - Missing environment variable
  - `ERR_MISSING_ARG=12` - Missing required argument
  - `ERR_MISSING_CONF=13` - Missing/invalid configuration
  - `ERR_USAGE=14` - Usage error
  - `ERR_BACKUP_FAILED=15` - Backup operation failed
  - `ERR_DISK_SPACE=16` - Insufficient disk space
  - `ERR_RESTORE_FAILED=17` - Restore operation failed
  - `ERR_UNSAFE_VOLUME=18` - Unsafe volume operation
  - `ERR_UNKNOWN=99` - Unknown error

### logging.sh
- **Purpose**: Standardized logging across scripts
- **Key Functions**:
  - `log(message)` - Standard logging with timestamps
  - `log_json(level, message, event_type, ...)` - nginx-format logging for New Relic
  - `log_simple(message)` - Simple logging for entrypoint scripts
  - `die(message, [exit_code])` - Log error and exit
- **Configuration Variables**:
  - `LOG_FILE` - Path to log file (optional)
  - `NGINX_LOG_FILE` - Path to nginx-format log (optional)
  - `SCRIPT_NAME` - Script name for context (optional)

### aws_utils.sh
- **Purpose**: AWS credential validation and helpers
- **Key Functions**:
  - `check_aws_credentials()` - Validate AWS credentials are set
  - `check_s3_config()` - Validate S3 configuration
  - `validate_aws_and_s3()` - Validate both (dies on failure)
  - `configure_aws_cli()` - Configure AWS CLI with credentials
  - `get_s3_bucket()` - Extract bucket name from s3_url

### docker_utils.sh
- **Purpose**: Docker and Docker Compose operation wrappers
- **Key Functions**:
  - `compose_exec(command, args...)` - Execute in container
  - `compose_cp(source, dest)` - Copy files from/to container
  - `compose_up()` - Start service
  - `compose_down()` - Stop service
  - `compose_restart()` - Restart service
  - `get_compose_network()` - Get compose network name
  - `get_full_volume_name(volume)` - Get full Docker volume name
  - `check_docker_running()` - Verify Docker daemon is accessible
  - `check_required_commands(cmd1, cmd2, ...)` - Check command availability

### s3_utils.sh
- **Purpose**: S3 operations using pg_backctl Docker image
- **Key Functions**:
  - `s3_upload_directory(local_dir, s3_path)` - Upload directory to S3
  - `s3_download_directory(s3_path, local_dir)` - Download from S3
  - `s3_list_backups(s3_prefix)` - List backups (returns JSON)
  - `s3_delete_backup(backup_path)` - Delete backup from S3
  - `run_aws_command(aws_command, [env_vars...])` - Run custom AWS CLI command

## Usage Example

```bash
#!/bin/bash

# Source required libraries
SCRIPT_DIR="$( cd "$( dirname "${BASH_REMATCH[0]}" )" &>/dev/null && pwd )"
source "$SCRIPT_DIR/lib/error_codes.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config_parser.sh"
source "$SCRIPT_DIR/lib/docker_utils.sh"

# Set up logging
SCRIPT_NAME="my_script"
LOG_FILE="logs/my_script.log"

# Check required commands
check_required_commands "docker" "sed" "grep"

# Define config handler
my_config_handler() {
  local section="$1"
  local key="$2"
  local value="$3"

  case "$section" in
    database)
      case "$key" in
        service) service="$value" ;;
        port) db_port="$value" ;;
      esac
      ;;
  esac
}

# Parse configuration
parse_config_file "config.conf" my_config_handler

# Use Docker utilities
compose_exec pg_basebackup -h localhost -U postgres -D /backup

# Log with standard format
log "Backup completed successfully"
```

## Benefits

1. **Eliminates ~300 lines of duplicated code**
2. **Consistent error handling** across all scripts
3. **Standardized logging** format
4. **Easier maintenance** - fix bugs in one place
5. **Better testability** - libraries can be unit tested
6. **Clear separation of concerns**
