#!/bin/bash

set -euo pipefail

# Get script directory and source shared libraries
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "$SCRIPT_DIR/lib/error_codes.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker_utils.sh"

# Set up logging context
SCRIPT_NAME="pg_backctl"

# Check for required commands
check_required_commands pg_basebackup tar grep

# Function to perform pg_basebackup
create_backup() {
  local host="${DB_HOST:-localhost}"
  local port="${DB_PORT:-5432}"
  local user="${DB_USER:-postgres}"
  local compression_flag="${COMPRESSION_FLAG:-}"

  log_simple "Starting pg_basebackup from $host:$port as user $user"
  log_simple "Output directory: /backup"

  # Run pg_basebackup
  pg_basebackup -h "$host" -p "$port" -U "$user" -D /backup -Ft $compression_flag -P -v

  log_simple "Backup completed"
  ls -lh /backup
}

# Function to upload backup to S3
upload_to_s3() {
  local bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"
  local label="${BACKUP_LABEL}"

  log_simple "Uploading backup to S3: s3://$bucket/$label/"

  # Configure AWS CLI
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  # Upload files to S3
  aws s3 cp /backup/ "s3://$bucket/$label/" --recursive --endpoint-url "$S3_ENDPOINT"

  log_simple "Upload completed to s3://$bucket/$label/"
}

# Main logic
log_simple "Backup mode"

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
  log_simple "Local backup mode - files saved to /backup"
fi

log_simple "Backup operation completed successfully"
