#!/bin/bash

set -euo pipefail

# Check for required commands
for cmd in pg_basebackup tar grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' not found in PATH. Please install it before running this script." >&2
    exit 10
  fi
done

# Function to perform pg_basebackup
create_backup() {
  local host="${DB_HOST:-localhost}"
  local port="${DB_PORT:-5432}"
  local user="${DB_USER:-postgres}"
  local compression_flag="${COMPRESSION_FLAG:-}"

  echo "[ODO] Starting pg_basebackup from $host:$port as user $user"
  echo "[ODO] Output directory: /backup"

  # Run pg_basebackup
  pg_basebackup -h "$host" -p "$port" -U "$user" -D /backup -Ft $compression_flag -P -v

  echo "[ODO] Backup completed"
  ls -lh /backup
}

# Function to upload backup to S3
upload_to_s3() {
  local bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"
  local label="${BACKUP_LABEL}"

  echo "[ODO] Uploading backup to S3: s3://$bucket/$label/"

  # Configure AWS CLI
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  # Upload files to S3
  aws s3 cp /backup/ "s3://$bucket/$label/" --recursive --endpoint-url "$S3_ENDPOINT"

  echo "[ODO] Upload completed to s3://$bucket/$label/"
}

# Main logic
echo "[ODO] Backup mode"

# Perform backup
create_backup

# Upload to S3 if configured
if [[ -n "${S3_BACKUP_URL:-}" ]]; then
  # Check if aws command is available
  if ! command -v aws >/dev/null 2>&1; then
    echo "[ODO] AWS CLI not found, cannot upload to S3" >&2
    exit 10
  fi
  upload_to_s3
else
  echo "[ODO] Local backup mode - files saved to /backup"
fi

echo "[ODO] Backup operation completed successfully"
