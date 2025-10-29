#!/bin/bash

# S3 utilities for pg_backctl
# Provides common S3 operations using the pg_backctl Docker image

# Run AWS CLI command in Docker container
# Usage: run_aws_command "aws s3 ls ..." [additional_env_vars...]
# Additional env vars should be in format: -e KEY=VALUE
run_aws_command() {
  local aws_command="$1"
  shift

  local bucket
  bucket=$(get_s3_bucket)

  docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_BUCKET="$bucket" \
    "$@" \
    --entrypoint bash \
    "$pg_backctl_image" \
    -c "aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        $aws_command"
}

# Upload directory to S3
# Usage: s3_upload_directory "/local/path" "s3-prefix/backup-label"
s3_upload_directory() {
  local local_dir="$1"
  local s3_path="$2"
  local bucket
  bucket=$(get_s3_bucket)

  # Remove any duplicate slashes from path
  s3_path="${s3_path//\/\//\/}"

  log "Uploading backup to S3: s3://$bucket/$s3_path/"

  # Count files to upload
  local file_count
  file_count=$(find "$local_dir" -type f | wc -l)
  log "Files to upload: $file_count"

  # Run docker with volume mount for local directory
  if ! docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_PATH="$s3_path" \
    -e S3_BUCKET="$bucket" \
    -v "$local_dir":/backup \
    --entrypoint bash \
    "$pg_backctl_image" \
    -c "set -e && \
        aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        echo 'Starting S3 upload...' && \
        aws s3 cp /backup/ \"s3://\$S3_BUCKET/\$S3_PATH/\" --recursive --endpoint-url \"\$S3_ENDPOINT\" && \
        echo 'Verifying upload...' && \
        uploaded_count=\$(aws s3 ls \"s3://\$S3_BUCKET/\$S3_PATH/\" --endpoint-url \"\$S3_ENDPOINT\" --recursive | wc -l) && \
        echo \"Uploaded files: \$uploaded_count\" && \
        echo \"Upload completed to s3://\$S3_BUCKET/\$S3_PATH/\""; then
    die "S3 upload failed. Check AWS credentials, endpoint, and network connectivity." $ERR_BACKUP_FAILED
  fi

  log "S3 upload completed successfully"
}

# Download directory from S3
# Usage: s3_download_directory "s3-prefix/backup-label" "/local/path"
s3_download_directory() {
  local s3_path="$1"
  local local_dir="$2"
  local bucket
  bucket=$(get_s3_bucket)

  # Remove any duplicate slashes from path
  s3_path="${s3_path//\/\//\/}"

  log "Downloading from S3: s3://$bucket/$s3_path/ to $local_dir"

  # Create local directory if it doesn't exist
  mkdir -p "$local_dir"

  # Run docker with volume mount for local directory
  if ! docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_PATH="$s3_path" \
    -e S3_BUCKET="$bucket" \
    -v "$local_dir":/backup \
    --entrypoint bash \
    "$pg_backctl_image" \
    -c "set -e && \
        aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        echo 'Starting S3 download...' && \
        aws s3 cp \"s3://\$S3_BUCKET/\$S3_PATH/\" /backup/ --recursive --endpoint-url \"\$S3_ENDPOINT\" && \
        echo \"Download completed from s3://\$S3_BUCKET/\$S3_PATH/\""; then
    die "S3 download failed. Check AWS credentials, endpoint, and network connectivity." $ERR_RESTORE_FAILED
  fi

  log "S3 download completed successfully"
}

# List backups in S3
# Usage: backups_json=$(s3_list_backups "s3-prefix")
# Returns JSON array of backup objects sorted by LastModified (newest first)
s3_list_backups() {
  local s3_prefix="$1"
  local bucket
  bucket=$(get_s3_bucket)

  docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_BUCKET="$bucket" \
    -e S3_PREFIX="$s3_prefix" \
    --entrypoint bash \
    "$pg_backctl_image" \
    -c "aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        aws s3api list-objects-v2 \
          --bucket \"\$S3_BUCKET\" \
          --prefix \"\$S3_PREFIX/\" \
          --endpoint \"\$S3_ENDPOINT\" \
          --query 'reverse(sort_by(Contents, &LastModified))' \
          --output json" 2>/dev/null
}

# Delete backup from S3
# Usage: s3_delete_backup "s3-prefix/backup-label"
s3_delete_backup() {
  local backup_path="$1"
  local bucket
  bucket=$(get_s3_bucket)

  log "Deleting backup from S3: s3://$bucket/$backup_path/"

  if docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_BUCKET="$bucket" \
    -e BACKUP_PATH="$backup_path" \
    --entrypoint bash \
    "$pg_backctl_image" \
    -c "aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        aws s3 rm \"s3://\$S3_BUCKET/\$BACKUP_PATH/\" --recursive --endpoint-url \"\$S3_ENDPOINT\"" >/dev/null 2>&1; then
    return 0
  else
    log "WARNING: Failed to delete backup: $backup_path"
    return 1
  fi
}
