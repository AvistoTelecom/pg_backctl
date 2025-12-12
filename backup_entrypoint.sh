#!/bin/bash

set -euo pipefail

# Get script directory and source shared libraries
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "$SCRIPT_DIR/lib/error_codes.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker_utils.sh"

# Set up logging context
SCRIPT_NAME="pg_backctl_container"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Unified log file for all pg_backctl scripts
LOG_FILE="$LOG_DIR/pg_backctl.log"

# Rotate logs before starting (keep last 5 logs)
rotate_logs "$LOG_FILE" 5

# Check for required commands
check_required_commands pg_basebackup tar grep

# Function to perform pg_basebackup
create_backup() {
  local host="${DB_HOST:-localhost}"
  local port="${DB_PORT:-5432}"
  local user="${DB_USER:-postgres}"
  local compression_flag="${COMPRESSION_FLAG:-}"

  log "Starting pg_basebackup from $host:$port as user $user" \
    "event=pg_basebackup_start" \
    "db_host=$host" \
    "db_port=$port" \
    "db_user=$user"

  log "Output directory: /backup" \
    "event=backup_output_dir" \
    "output_dir=/backup"

  # Run pg_basebackup
  pg_basebackup -h "$host" -p "$port" -U "$user" -D /backup -Ft $compression_flag -P -v

  log "Backup completed" \
    "event=pg_basebackup_completed"

  ls -lh /backup
}

# Function to upload backup to S3
upload_to_s3() {
  local bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"
  local label="${BACKUP_LABEL}"

  log "Uploading backup to S3: s3://$bucket/$label/" \
    "event=s3_upload_start" \
    "s3_bucket=$bucket" \
    "backup_label=$label"

  # Configure AWS CLI
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  # Upload files to S3
  aws s3 cp /backup/ "s3://$bucket/$label/" --recursive --endpoint-url "$S3_ENDPOINT"

  log "Upload completed to s3://$bucket/$label/" \
    "event=s3_upload_completed" \
    "s3_destination=s3://$bucket/$label/"
}

# Main logic
log "Backup mode" \
  "event=container_start" \
  "mode=backup"

# Perform backup
create_backup

# Upload to S3 if configured
if [[ -n "${S3_BACKUP_URL:-}" ]]; then
  # Check if aws command is available
  if ! command -v aws >/dev/null 2>&1; then
    die "AWS CLI not found, cannot upload to S3" $ERR_MISSING_CMD
  fi
  upload_to_s3
else
  log "Local backup mode - files saved to /backup" \
    "event=local_backup_mode" \
    "backup_path=/backup"
fi

log "Backup operation completed successfully" \
  "event=container_completed"
