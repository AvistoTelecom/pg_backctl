#!/bin/bash

set -euo pipefail

# Get script directory and source shared libraries
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "$SCRIPT_DIR/lib/error_codes.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config_parser.sh"
source "$SCRIPT_DIR/lib/aws_utils.sh"
source "$SCRIPT_DIR/lib/docker_utils.sh"

# Set up logging context
SCRIPT_NAME="create_backup"

# Global variables for cleanup and enrichment
TEMP_BACKUP_DIR=""
LOG_FILE=""
BACKUP_START_TIME=""
BACKUP_LABEL=""
DB_SIZE_BYTES=""
BACKUP_SIZE_BYTES=""


# Cleanup function for trap
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Script failed with exit code $exit_code, cleaning up..." "error_code=$exit_code"

    # Log failure event with all available context
    if [ -n "$BACKUP_START_TIME" ]; then
      local failure_time=$(date +%s)
      local duration=$((failure_time - BACKUP_START_TIME))

      log_json "ERROR" "Backup failed" \
        "event=backup.fail" \
        "status=failure" \
        "backup_label=${BACKUP_LABEL:-unknown}" \
        "duration_seconds=$duration" \
        "exit_code=$exit_code" \
        "compression=${compression:-unknown}" \
        "db_host=${db_host:-unknown}" \
        "db_port=${db_port:-unknown}" \
        "destination=${backup_path:-${s3_url:-unknown}}"
    fi

    # Clean up temporary backup directory if it exists
    if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
      log "Removing temporary backup directory: $TEMP_BACKUP_DIR"
      rm -rf "$TEMP_BACKUP_DIR"
    fi

    # Clean up /tmp/backup in container if it exists
    if [ -n "${service:-}" ] && [ -n "${compose_filepath:-}" ]; then
      if [ -f "$compose_filepath" ]; then
        docker compose -f "$compose_filepath" exec -T "$service" rm -rf /tmp/backup 2>/dev/null || true
      fi
    fi
  fi
}

# Set trap for cleanup
trap cleanup_on_error EXIT ERR

# variables default values
pgversion="latest"
backup_path=""
s3_url=""
s3_endpoint=""
backup_label=""
compression="gzip"
encryption=""
incremental=""
db_host=""
db_port="5432"
db_user="postgres"
db_name=""
service=""
compose_filepath=""
pg_backctl_image="pg_backctl:latest"
config_file=""
min_disk_space_gb=""
disk_space_margin_gb="2"  # Safety margin to add to volume size when calculating required space
s3_backup_prefix="backups"  # Default prefix for S3 backups (e.g., "backups" -> s3://bucket/backups/LABEL/)
retention_count=""  # Keep last N backups (takes priority over retention_days)
retention_days=""   # Keep backups for N days
backup_label_regex="[0-9]{8}T[0-9]{6}"  # Default regex pattern for backup directory labels (YYYYMMDDTHHMMSS)

# Custom config handler for create_backup specific options
config_handler() {
  local section="$1"
  local key="$2"
  local value="$3"

  case "$section" in
    database)
      case "$key" in
        service) service="$value" ;;
        compose_file) compose_filepath="$value" ;;
        host) db_host="$value" ;;
        port) db_port="$value" ;;
        user) db_user="$value" ;;
        name) db_name="$value" ;;
        version) pgversion="$value" ;;
      esac
      ;;
    destination)
      case "$key" in
        path) backup_path="$value" ;;
        s3_url) s3_url="$value" ;;
        s3_endpoint) s3_endpoint="$value" ;;
        s3_prefix) s3_backup_prefix="$value" ;;
      esac
      ;;
    backup)
      case "$key" in
        label) backup_label="$value" ;;
        compression) compression="$value" ;;
        min_disk_space_gb) min_disk_space_gb="$value" ;;
        disk_space_margin_gb) disk_space_margin_gb="$value" ;;
        retention_count) retention_count="$value" ;;
        retention_days) retention_days="$value" ;;
        backup_label_regex) backup_label_regex="$value" ;;
      esac
      ;;
    aws)
      case "$key" in
        access_key) AWS_ACCESS_KEY="$value" ;;
        secret_key) AWS_SECRET_KEY="$value" ;;
        region) AWS_REGION="$value" ;;
      esac
      ;;
    docker)
      case "$key" in
        image) pg_backctl_image="$value" ;;
      esac
      ;;
    advanced)
      case "$key" in
        encryption) encryption="$value" ;;
        incremental) incremental="$value" ;;
      esac
      ;;
  esac
}

# Check for required commands
check_required_commands docker sed grep date

# Print usage/help
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  Configuration:
  -c, --config FILE     Load configuration from file (overrides defaults)

  Database connection:
  -n SERVICE_NAME       Docker Compose service name (required unless in config)
  -f COMPOSE_FILEPATH   Path to docker-compose file (required unless in config)
  -H DB_HOST            Database host (default: use service from compose)
  -T DB_PORT            Database port (default: 5432)
  -U DB_USER            Database user (default: postgres)
  -d DB_NAME            Database name (for connection, optional)

  Backup destination:
  -u S3_BACKUP_URL      S3 backup URL (e.g., s3://mybucket/backups)
  -e S3_ENDPOINT        S3 endpoint (required with -u)
  -P BACKUP_PATH        Local backup path (alternative to S3)

  Backup options:
  -l BACKUP_LABEL       Backup label/name (default: auto-generated timestamp)
  -C COMPRESSION        Compression method: gzip, bzip2, none (default: gzip)
  -E ENCRYPTION         Encryption passphrase (future: for pg_basebackup --encrypt)
  -I                    Incremental backup (future: requires base backup reference)
  -O PG_BACKCTL_IMAGE   pg_backctl docker image (default: pg_backctl:latest)
  -p PG_VERSION         Postgres version (default: latest)

  AWS credentials (optional, can be set in .env or config file):
  -a AWS_ACCESS_KEY     AWS access key
  -s AWS_SECRET_KEY     AWS secret key
  -r AWS_REGION         AWS region

  -h, --help            Show this help message and exit

Examples:
  # Using a config file
  $0 -c backup.conf

  # Config file with CLI override
  $0 -c backup.conf -l "manual-backup-$(date +%Y%m%d)"

  # Backup to S3 with gzip compression (no config file)
  $0 -n db-service -f docker-compose.yml -u s3://mybucket/backups -e https://s3.endpoint.com

  # Backup to local directory with bzip2 compression
  $0 -n db-service -f docker-compose.yml -P /backups/mydb -C bzip2

  # Backup with custom label
  $0 -n db-service -f docker-compose.yml -P /backups/mydb -l "pre-migration-backup"

  # Backup with custom database connection
  $0 -n db-service -f docker-compose.yml -H localhost -T 5432 -U replication -P /backups/mydb

Config File:
  See backup.conf.example for a complete configuration file example.
  Config file uses INI format with sections: [database], [destination], [backup], [aws], [docker]
  Command-line arguments override config file values.
EOF
}

# Function check AWS
check_aws() {
  if [ -z "${AWS_ACCESS_KEY:-}" ] || [ -z "${AWS_SECRET_KEY:-}" ] || [ -z "${AWS_REGION:-}" ]; then
    die "Missing AWS credentials. Ensure you have set AWS_ACCESS_KEY, AWS_SECRET_KEY and AWS_REGION in .env or via arguments." $ERR_MISSING_ENV
  fi
  if [ -z "${s3_url:-}" ] || [ -z "${s3_endpoint:-}" ]; then
    die "Missing S3 configuration. Both -u (S3_BACKUP_URL) and -e (S3_ENDPOINT) are required for S3 backup." $ERR_MISSING_ARG
  fi
}

# Function to get PostgreSQL data directory size in GB
get_postgres_volume_size_gb() {
  # Get the size of PostgreSQL data directory from inside the database container
  local volume_size_bytes
  volume_size_bytes=$(docker compose -f "$compose_filepath" exec -T "$service" \
    du -sb /var/lib/postgresql/data 2>/dev/null | awk '{print $1}') || {
    echo "0" >&2
    return 1
  }

  # Strip whitespace from result
  volume_size_bytes=$(echo "$volume_size_bytes" | tr -d '[:space:]')

  # Validate result is a number
  if ! [[ "$volume_size_bytes" =~ ^[0-9]+$ ]]; then
    echo "0" >&2
    return 1
  fi

  # Convert bytes to GB (round up)
  local volume_size_gb
  volume_size_gb=$(awk "BEGIN {printf \"%.0f\", ($volume_size_bytes + 1073741823) / 1073741824}")

  # Only output the number to stdout
  echo "$volume_size_gb"
}

# Function to check disk space
check_disk_space() {
  local target_dir="$1"
  local min_free_gb="${2:-5}"  # Default 5GB minimum

  # Get available space in GB
  local available_gb
  available_gb=$(df -BG "$target_dir" | awk 'NR==2 {print $4}' | sed 's/G//')

  log "Available disk space in $target_dir: ${available_gb}GB" \
    "event=disk.check.start" \
    "target_dir=$target_dir" \
    "available_gb=$available_gb" \
    "required_gb=$min_free_gb"

  if [ "$available_gb" -lt "$min_free_gb" ]; then
    die "Insufficient disk space in $target_dir. Available: ${available_gb}GB, Required: at least ${min_free_gb}GB" $ERR_DISK_SPACE
  fi

  log "Disk space check passed" \
    "event=disk.check.pass" \
    "status=passed" \
    "available_gb=$available_gb"
}

# Function check arguments
check_args() {
  if [ -z "${service:-}" ] || [ -z "${compose_filepath:-}" ]; then
    die "Missing required arguments: -n (service name) and -f (compose file path) are required." $ERR_MISSING_ARG
  fi

  # Check that either S3 or local path is specified
  if [ -z "${backup_path:-}" ] && [ -z "${s3_url:-}" ]; then
    die "You must specify either -P (local backup path) or -u/-e (S3 backup) as destination." $ERR_USAGE
  fi

  # Check that both are not specified
  if [ -n "${backup_path:-}" ] && [ -n "${s3_url:-}" ]; then
    die "You can't use -P (local backup) and -u/-e (S3 option) together. Choose one destination." $ERR_USAGE
  fi

  # If S3, check AWS credentials
  if [ -n "${s3_url:-}" ]; then
    check_aws
  fi

  # Determine required disk space
  local required_space_gb="$min_disk_space_gb"

  # If min_disk_space_gb is not set, calculate from volume size
  if [ -z "$required_space_gb" ]; then
    log "Querying PostgreSQL data directory size..." "event=db.size.query.start"
    local volume_size_gb
    volume_size_gb=$(get_postgres_volume_size_gb)

    if [ "$volume_size_gb" -gt 0 ] 2>/dev/null; then
      required_space_gb=$((volume_size_gb + disk_space_margin_gb))
      DB_SIZE_BYTES=$((volume_size_gb * 1073741824))  # Store for enrichment
      log "PostgreSQL data directory size: ${volume_size_gb}GB" \
        "event=db.size.detected" \
        "status=success" \
        "db_size_gb=$volume_size_gb" \
        "db_size_bytes=$DB_SIZE_BYTES"
      log "Calculated required disk space: ${volume_size_gb}GB (data directory) + ${disk_space_margin_gb}GB (margin) = ${required_space_gb}GB" \
        "event=disk.space.calculated" \
        "required_gb=$required_space_gb" \
        "data_gb=$volume_size_gb" \
        "margin_gb=$disk_space_margin_gb"
    else
      # Fallback to default if volume size query failed
      required_space_gb="5"
      log "WARNING: Failed to get data directory size, using default minimum disk space: ${required_space_gb}GB" \
        "event=db.size.query.fail" \
        "status=failure"
    fi
  fi

  # If local, ensure directory exists or can be created
  if [ -n "${backup_path:-}" ]; then
    mkdir -p "$backup_path" || die "Cannot create backup directory: $backup_path" $ERR_USAGE
    # Check disk space for local backups
    check_disk_space "$backup_path" "$required_space_gb"
  else
    # For S3 mode, check /tmp disk space
    check_disk_space "/tmp" "$required_space_gb"
  fi
}

# Function to determine compression flag for pg_basebackup
get_compression_flag() {
  case "$compression" in
    gzip)
      echo "-z"
      ;;
    bzip2)
      echo ""
      ;;
    none)
      echo ""
      ;;
    *)
      die "Unknown compression method: $compression. Use gzip, bzip2, or none." $ERR_USAGE
      ;;
  esac
}

# Function to generate backup label
generate_backup_label() {
  if [ -n "$backup_label" ]; then
    echo "$backup_label"
  else
    date +"%Y%m%dT%H%M%S"
  fi
}

# Function to validate retention policy values
validate_retention_values() {
  # Validate retention_count if set
  if [ -n "$retention_count" ]; then
    if ! [[ "$retention_count" =~ ^[0-9]+$ ]] || [ "$retention_count" -le 0 ]; then
      log "ERROR: retention_count must be a positive integer (got: '$retention_count')" "validation"
      return 1
    fi
  fi

  # Validate retention_days if set
  if [ -n "$retention_days" ]; then
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [ "$retention_days" -le 0 ]; then
      log "ERROR: retention_days must be a positive integer (got: '$retention_days')" "validation"
      return 1
    fi
  fi

  return 0
}

# Function to get database host from compose service
get_db_host_from_compose() {
  if [ -n "$db_host" ]; then
    echo "$db_host"
  else
    echo "$service"
  fi
}


# Function to create backup using database container
create_backup_from_db() {
  local backup_dir="$1"
  local host
  local compression_flag

  host=$(get_db_host_from_compose)
  compression_flag=$(get_compression_flag)

  log "Creating backup using database container" "backup_execution"

  # Create temporary directory inside the db container
  log "Creating temporary directory in container" "backup_execution"
  if ! compose_exec mkdir -p /tmp/backup; then
    die "Failed to create temporary directory in container" $ERR_BACKUP_FAILED
  fi

  # Run pg_basebackup inside the database container
  log "Running pg_basebackup..." "backup_execution"
  if [ -n "${PGPASSWORD:-}" ]; then
    compose_exec bash -c "PGPASSWORD='$PGPASSWORD' pg_basebackup -h $host -p $db_port -U $db_user -D /tmp/backup -Ft $compression_flag -P -v"
    local backup_exit_code=$?
  else
    compose_exec pg_basebackup -h "$host" -p "$db_port" -U "$db_user" -D /tmp/backup -Ft $compression_flag -P -v
    local backup_exit_code=$?
  fi

  # Check if pg_basebackup failed
  if [ $backup_exit_code -ne 0 ]; then
    log "ERROR: pg_basebackup failed with exit code $backup_exit_code" "backup_failed"
    log "Cleaning up failed backup attempt..." "backup_cleanup"
    compose_exec rm -rf /tmp/backup 2>/dev/null || true
    die "Database backup failed - check database connection and credentials" $ERR_BACKUP_FAILED
  fi

  log "pg_basebackup completed successfully" "backup_execution"

  # Copy backup files from container to host
  log "Copying backup files from container to host..." "backup_execution"
  if ! compose_cp "$service":/tmp/backup/. "$backup_dir/"; then
    log "ERROR: Failed to copy backup files from container" "backup_failed"
    compose_exec rm -rf /tmp/backup 2>/dev/null || true
    die "Failed to copy backup files from container to host" $ERR_BACKUP_FAILED
  fi

  # Cleanup temporary directory in container
  log "Cleaning up container temporary directory" "backup_cleanup"
  if ! compose_exec rm -rf /tmp/backup; then
    log "WARNING: Failed to cleanup temporary directory in container" "backup_cleanup"
  fi

  log "Backup files copied to $backup_dir" "backup_execution"
  ls -lh "$backup_dir" | tee -a "$LOG_FILE"

  # Post-process with bzip2 if needed
  if [ "$compression" = "bzip2" ]; then
    log "Compressing backup files with bzip2..." "backup_compression"
    for tarfile in "$backup_dir"/*.tar; do
      if [ -f "$tarfile" ]; then
        local filesize=$(du -h "$tarfile" | cut -f1)
        log "Compressing $(basename "$tarfile") ($filesize) - this may take several minutes..." "backup_compression"

        # Use pv if available for progress, otherwise use plain bzip2
        local bz2_file="$tarfile.bz2"
        if command -v pv >/dev/null 2>&1; then
          if pv "$tarfile" | bzip2 -9 > "$bz2_file"; then
            log "Compression successful, removing original tar file" "backup_compression"
            rm "$tarfile"
          else
            log "ERROR: bzip2 compression failed for $(basename "$tarfile"), keeping original" "backup_failed"
            rm -f "$bz2_file"  # Remove partial bz2 file
            die "Compression failed for $(basename "$tarfile")" $ERR_BACKUP_FAILED
          fi
        else
          if bzip2 -9 -v "$tarfile"; then
            log "Compression successful" "backup_compression"
          else
            log "ERROR: bzip2 compression failed for $(basename "$tarfile")" "backup_failed"
            die "Compression failed for $(basename "$tarfile")" $ERR_BACKUP_FAILED
          fi
        fi
      fi
    done
    log "Compression completed" "backup_compression"
    ls -lh "$backup_dir" | tee -a "$LOG_FILE"
  fi
}

# Function to upload backup to S3 using pg_backctl image
upload_backup_to_s3() {
  local backup_dir="$1"
  local label="$2"
  local bucket="${s3_url#s3://}"
  bucket="${bucket%/}"

  # Build S3 path with prefix (e.g., backups/20250124T143000)
  local s3_path="${s3_backup_prefix}/${label}"
  # Remove any duplicate slashes
  s3_path="${s3_path//\/\//\/}"

  log "Uploading backup to S3: s3://$bucket/$s3_path/" "s3_upload"
  log "Using S3 prefix: $s3_backup_prefix" "s3_upload"

  # Count files to upload
  local file_count
  file_count=$(find "$backup_dir" -type f | wc -l)
  log "Files to upload: $file_count" "s3_upload"

  # Run docker with explicit error handling
  if ! docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_PATH="$s3_path" \
    -e S3_BUCKET="$bucket" \
    -v "$backup_dir":/backup \
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

  log "S3 upload completed successfully" "s3_upload"
}

# Function to generate checksums for backup files
generate_checksums() {
  local backup_dir="$1"
  local label="$2"
  local checksum_file="$backup_dir/backup.sha256"
  local metadata_file="$backup_dir/backup.sha256.info"

  log "Generating SHA256 checksums for backup integrity verification..." "backup_checksum"

  # Generate checksums for all files (excluding checksum/metadata files themselves)
  (cd "$backup_dir" && find . -type f ! -name "backup.sha256*" -exec sha256sum {} \; | sort -k2) > "$checksum_file"

  local file_count
  file_count=$(wc -l < "$checksum_file")

  log "Generated checksums for $file_count files" "backup_checksum"
  log "Checksum manifest: $checksum_file" "backup_checksum"

  # Create metadata file explaining the checksum format
  cat > "$metadata_file" <<EOF
# pg_backctl Backup Checksum Metadata
# This file describes the checksum manifest format for verification tools

backup_label: $label
backup_timestamp: $(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
checksum_algorithm: SHA256
checksum_tool: sha256sum (GNU coreutils)
manifest_file: backup.sha256

# Manifest Format:
# Each line contains: <sha256_hash>  <relative_filepath>
# Example:
#   abc123def456...  ./base.tar.gz
#   def456abc789...  ./pg_wal.tar.gz

# How to Verify:
# 1. Download the backup directory from S3
# 2. Run: sha256sum -c backup.sha256
# 3. All files should report "OK"

# Files in this backup:
$(cat "$checksum_file" | awk '{print "#   " $2}')

# Total files: $file_count
# Generated by: pg_backctl
# Version: 1.3.0
EOF

  log "Generated checksum metadata: $metadata_file" \
    "event=checksum.metadata.generated" \
    "status=success" \
    "metadata_file=$metadata_file"

  # Log first few checksums for debugging (no event type - just informational)
  log "Sample checksums:" "event=checksum.sample"
  head -n 3 "$checksum_file" | while read -r line; do
    log "  $line"
  done

  log "Checksums generated" \
    "event=checksum.complete" \
    "status=success" \
    "file_count=$file_count" \
    "checksum_file=backup.sha256" \
    "metadata_file=backup.sha256.info" \
    "algorithm=SHA256"
}

# Function to cleanup old backups based on retention policy
cleanup_old_backups() {
  local bucket="${s3_url#s3://}"
  bucket="${bucket%/}"

  # Check if retention policy is configured
  if [ -z "${retention_count:-}" ] && [ -z "${retention_days:-}" ]; then
    log "No retention policy configured, skipping cleanup" \
      "event=retention.cleanup.skip" \
      "status=skipped" \
      "retention_config=none"
    return 0
  fi

  # Validate retention values
  if ! validate_retention_values; then
    log "ERROR: Invalid retention policy values, skipping S3 cleanup" \
      "event=retention.validation.fail" \
      "status=failure"
    return 1
  fi

  local retention_config="${retention_count:+count=$retention_count}${retention_days:+days=$retention_days}"
  log "Applying retention policy to S3 backups..." \
    "event=retention.cleanup.start" \
    "retention_config=$retention_config"

  # List all backups in the prefix, sorted by LastModified (newest first)
  local backup_list
  backup_list=$(docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e S3_BUCKET="$bucket" \
    -e S3_PREFIX="${s3_backup_prefix}" \
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
          --output json" 2>/dev/null) || {
    log "WARNING: Failed to list backups for retention cleanup" "retention_policy"
    return 0
  }

  # Extract unique backup directories (everything up to the first file)
  local backup_dirs
  backup_dirs=$(echo "$backup_list" | docker run -i --rm \
    --entrypoint python3 \
    "$pg_backctl_image" \
    -c "
import json, sys
from datetime import datetime, timedelta

data = json.load(sys.stdin)
if not data:
    sys.exit(0)

# Group files by backup directory
backups = {}
for item in data:
    key = item['Key']
    # Extract backup dir (e.g., 'backups/20250124T143000')
    parts = key.split('/')
    if len(parts) >= 2:
        backup_dir = '/'.join(parts[:-1])  # Everything except filename
        if backup_dir not in backups:
            backups[backup_dir] = {
                'dir': backup_dir,
                'last_modified': item['LastModified']
            }

# Sort by last_modified (newest first)
sorted_backups = sorted(backups.values(), key=lambda x: x['last_modified'], reverse=True)

# Apply retention policy
retention_count = ${retention_count:-0}
retention_days = ${retention_days:-0}
to_delete = []

for i, backup in enumerate(sorted_backups):
    keep = False

    # Priority 1: retention_count
    if retention_count > 0 and i < retention_count:
        keep = True
    # Priority 2: retention_days (if no retention_count)
    elif retention_days > 0 and retention_count == 0:
        modified = datetime.fromisoformat(backup['last_modified'].replace('Z', '+00:00'))
        age_days = (datetime.now(modified.tzinfo) - modified).days
        if age_days < retention_days:
            keep = True

    if not keep:
        to_delete.append(backup['dir'])

# Output directories to delete
for dir_path in to_delete:
    print(dir_path)
" 2>/dev/null) || {
    log "WARNING: Failed to process backup list for retention" "retention_policy"
    return 0
  }

  # Delete old backups
  if [ -z "$backup_dirs" ]; then
    log "No old backups to delete (retention policy satisfied)" \
      "event=retention.cleanup.complete" \
      "status=satisfied" \
      "backups_before_cleanup=0" \
      "deleted_count=0"
    return 0
  fi

  local total_backups=$(echo "$backup_dirs" | wc -l)
  local delete_count=0
  while IFS= read -r backup_dir; do
    [ -z "$backup_dir" ] && continue

    log "Deleting old backup: s3://$bucket/$backup_dir/" \
      "event=retention.backup.delete" \
      "backup_dir=$backup_dir"

    if docker run -t --rm \
      -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
      -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
      -e AWS_DEFAULT_REGION="$AWS_REGION" \
      -e S3_ENDPOINT="$s3_endpoint" \
      -e S3_BUCKET="$bucket" \
      -e BACKUP_DIR="$backup_dir" \
      --entrypoint bash \
      "$pg_backctl_image" \
      -c "aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
          aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
          aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
          aws s3 rm \"s3://\$S3_BUCKET/\$BACKUP_DIR/\" --recursive --endpoint-url \"\$S3_ENDPOINT\"" >/dev/null 2>&1; then
      ((delete_count++))
      log "Deleted old backup: $backup_dir" \
        "event=retention.backup.deleted" \
        "status=success" \
        "backup_dir=$backup_dir"
    else
      log "WARNING: Failed to delete backup: $backup_dir" \
        "event=retention.backup.delete.fail" \
        "status=failure" \
        "backup_dir=$backup_dir"
    fi
  done <<< "$backup_dirs"

  if [ $delete_count -gt 0 ]; then
    log "Retention policy: deleted $delete_count old backup(s)" \
      "event=retention.cleanup.complete" \
      "status=success" \
      "backups_before_cleanup=$total_backups" \
      "deleted_count=$delete_count" \
      "retention_config=$retention_config"
  fi
}

# Function to cleanup old local backups based on retention policy
cleanup_old_local_backups() {
  local backup_root="$1"  # Root backup directory (e.g., /backups/postgres)

  # Check if retention policy is configured
  if [ -z "${retention_count:-}" ] && [ -z "${retention_days:-}" ]; then
    log "No retention policy configured, skipping cleanup" "retention_policy"
    return 0
  fi

  # Validate retention values
  if ! validate_retention_values; then
    log "ERROR: Invalid retention policy values, skipping local cleanup" "retention_policy"
    return 1
  fi

  log "Applying retention policy to local backups in $backup_root..." "retention_policy"

  # Find all backup directories (directories matching backup_label_regex pattern)
  local backup_dirs
  backup_dirs=$(find "$backup_root" -maxdepth 1 -type d -regextype posix-extended \
    -regex ".*/${backup_label_regex}" -printf "%T@ %p\n" 2>/dev/null | sort -rn | awk '{print $2}')

  if [ -z "$backup_dirs" ]; then
    log "No backups found in $backup_root" "retention_policy"
    return 0
  fi

  local backup_count
  backup_count=$(echo "$backup_dirs" | wc -l)
  log "Found $backup_count backup(s) in $backup_root" "retention_policy"

  # Determine which backups to delete
  local to_delete=()
  local index=0

  while IFS= read -r backup_dir; do
    [ -z "$backup_dir" ] && continue

    local keep=false

    # Priority 1: retention_count
    if [ -n "$retention_count" ] && [ "$retention_count" -gt 0 ]; then
      if [ $index -lt "$retention_count" ]; then
        keep=true
      fi
    # Priority 2: retention_days (if no retention_count)
    elif [ -n "$retention_days" ] && [ "$retention_days" -gt 0 ]; then
      local dir_mtime
      dir_mtime=$(stat -c %Y "$backup_dir" 2>/dev/null || echo "0")
      local current_time
      current_time=$(date +%s)
      local age_days=$(( (current_time - dir_mtime) / 86400 ))

      if [ "$age_days" -lt "$retention_days" ]; then
        keep=true
      fi
    fi

    if [ "$keep" = false ]; then
      to_delete+=("$backup_dir")
    fi

    ((index++))
  done <<< "$backup_dirs"

  # Delete old backups
  if [ ${#to_delete[@]} -eq 0 ]; then
    log "No old backups to delete (retention policy satisfied)" "retention_policy"
    return 0
  fi

  local delete_count=0
  for backup_dir in "${to_delete[@]}"; do
    log "Deleting old backup: $backup_dir" "retention_cleanup"

    if rm -rf "$backup_dir"; then
      ((delete_count++))
      log_json "INFO" "Deleted old backup: $(basename "$backup_dir")" "retention_cleanup" "backup_dir=$backup_dir"
    else
      log "WARNING: Failed to delete backup: $backup_dir" "retention_cleanup"
    fi
  done

  if [ $delete_count -gt 0 ]; then
    log "Retention policy: deleted $delete_count old backup(s)" \
      "event=retention.cleanup.complete" \
      "status=success" \
      "backups_before_cleanup=$backup_count" \
      "deleted_count=$delete_count" \
      "retention_config=$retention_config"
  fi
}

# Function to run backup with S3 storage
run_backup_s3() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
  generate_checksums "$backup_dir" "$label"
  upload_backup_to_s3 "$backup_dir" "$label"
  log "Checksum manifest uploaded to S3 for external verification" "s3_upload"
  cleanup_old_backups
}

# Function to run backup with local storage
run_backup_local() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
  generate_checksums "$backup_dir" "$label"
  log "Local backup complete with checksum manifest:" "backup_completed"
  log "  - Checksums: $backup_dir/backup.sha256"
  log "  - Metadata: $backup_dir/backup.sha256.info"

  # Apply retention policy to local backups
  local backup_root
  backup_root=$(dirname "$backup_dir")
  cleanup_old_local_backups "$backup_root"
}

# Main backup orchestration function
run_backup() {
  local label
  local abs_backup_path

  label=$(generate_backup_label)
  BACKUP_LABEL="$label"  # Store globally for error logging

  log "Starting backup from $(get_db_host_from_compose):$db_port as user $db_user" \
    "event=backup.start" \
    "status=started" \
    "db_host=$(get_db_host_from_compose)" \
    "db_port=$db_port" \
    "db_user=$db_user" \
    "backup_label=$label" \
    "compression=$compression"

  # Prepare backup directory
  if [ -n "$backup_path" ]; then
    # Convert to absolute path if needed
    if [[ "$backup_path" = /* ]]; then
      abs_backup_path="$backup_path"
    else
      abs_backup_path="$(pwd)/$backup_path"
    fi
  else
    # For S3, use temporary local directory
    abs_backup_path="/tmp/pg_backctl_backup_$$"
    # Mark this as temporary for cleanup
    TEMP_BACKUP_DIR="$abs_backup_path"
  fi

  mkdir -p "$abs_backup_path/$label"

  # Run backup (S3 or local mode)
  if [ -n "$s3_url" ]; then
    run_backup_s3 "$abs_backup_path/$label" "$label" || die "Backup failed" $ERR_BACKUP_FAILED
  else
    run_backup_local "$abs_backup_path/$label" "$label" || die "Backup failed" $ERR_BACKUP_FAILED
  fi

  # Calculate backup metrics
  local backup_end_time=$(date +%s)
  local duration=$((backup_end_time - BACKUP_START_TIME))
  local backup_size_bytes=$(du -sb "$abs_backup_path/$label" 2>/dev/null | cut -f1)
  local backup_size_mb=$((backup_size_bytes / 1024 / 1024))
  local backup_size_gb=$(awk "BEGIN {printf \"%.2f\", $backup_size_bytes / 1073741824}")
  local file_count=$(find "$abs_backup_path/$label" -type f | wc -l)
  BACKUP_SIZE_BYTES="$backup_size_bytes"  # Store for enrichment

  # Cleanup temporary directory if used for S3 (explicit check)
  if [ -n "$s3_url" ] && [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
    log "Cleaning up temporary backup directory: $TEMP_BACKUP_DIR" \
      "event=backup_cleanup"
    rm -rf "$TEMP_BACKUP_DIR"
    TEMP_BACKUP_DIR=""  # Clear to avoid double cleanup in trap
  fi

  # Determine destination
  local destination
  if [ -n "$backup_path" ]; then
    destination="local:$backup_path/$label"
  else
    destination="s3:$s3_url/${s3_backup_prefix}/$label"
  fi

  # Determine retention config
  local retention_config="${retention_count:+count=$retention_count}${retention_days:+days=$retention_days}"
  [ -z "$retention_config" ] && retention_config="none"

  log "Backup completed successfully" \
    "event=backup.complete" \
    "status=success" \
    "backup_label=$label" \
    "duration_seconds=$duration" \
    "db_size_bytes=${DB_SIZE_BYTES:-0}" \
    "backup_size_human=${backup_size_gb}GB" \
    "backup_size_bytes=$backup_size_bytes" \
    "backup_destination=$destination" \
    "retention_config=$retention_config" \
    "compression=$compression" \
    "file_count=$file_count" \
    "db_host=$(get_db_host_from_compose)" \
    "db_port=$db_port"
}

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"

# Parse command line arguments (first pass - check for config file)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      config_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      # Store remaining args for second pass
      break
      ;;
  esac
done

# Load .env file first (lowest priority)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Load config file if specified (medium priority - overrides .env)
if [ -n "$config_file" ]; then
  parse_config_file "$config_file" config_handler
  echo "Configuration loaded from: $config_file"
fi

# Parse remaining command line arguments (highest priority - overrides config file)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a) AWS_ACCESS_KEY="$2"; shift 2;;
    -s) AWS_SECRET_KEY="$2"; shift 2;;
    -r) AWS_REGION="$2"; shift 2;;
    -u) s3_url="$2"; shift 2;;
    -e) s3_endpoint="$2"; shift 2;;
    -P) backup_path="$2"; shift 2;;
    -l) backup_label="$2"; shift 2;;
    -C) compression="$2"; shift 2;;
    -E) encryption="$2"; shift 2;;
    -I) incremental="true"; shift;;
    -n) service="$2"; shift 2;;
    -f) compose_filepath="$2"; shift 2;;
    -H) db_host="$2"; shift 2;;
    -T) db_port="$2"; shift 2;;
    -U) db_user="$2"; shift 2;;
    -d) db_name="$2"; shift 2;;
    -O) pg_backctl_image="$2"; shift 2;;
    -p) pgversion="$2"; shift 2;;
    -c|--config) shift 2;;  # Already handled in first pass
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "Unknown option: $1"; usage; exit 1;;
    *) break;;
  esac
done

# Initialize unified log file
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Unified log file for all pg_backctl scripts
LOG_FILE="$LOG_DIR/pg_backctl.log"

# Rotate logs before starting (keep last 5 logs)
rotate_logs "$LOG_FILE" 5

# Record start time for metrics
BACKUP_START_TIME=$(date +%s)

log "Backup script started" \
  "event=script.start" \
  "status=started" \
  "log_file=$LOG_FILE"

# Log start event with metadata
log "Backup initialization" \
  "event=backup.init" \
  "backup_type=pg_basebackup" \
  "compression=$compression"

# Validate arguments
check_args

# Execute backup
run_backup

# Log completion
log "Backup script completed successfully" \
  "event=script.complete" \
  "status=success"
