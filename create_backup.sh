#!/bin/bash

set -euo pipefail

# Error codes
ERR_MISSING_CMD=10      # Required command not found
ERR_MISSING_ENV=11      # Missing required environment variable
ERR_MISSING_ARG=12      # Missing required argument
ERR_USAGE=14            # Usage error (bad arg combination)
ERR_BACKUP_FAILED=15    # Backup operation failed
ERR_DISK_SPACE=16       # Insufficient disk space
ERR_UNKNOWN=99          # Unknown error

# Global variables for cleanup
TEMP_BACKUP_DIR=""
LOG_FILE=""
NGINX_LOG_FILE=""
BACKUP_START_TIME=""
BACKUP_LABEL=""

# Escape JSON strings
json_escape() {
  local string="$1"
  # Escape backslashes, quotes, and newlines
  echo "$string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

# Logging function for New Relic (nginx format)
log_json() {
  local level="$1"
  local message="$2"
  local event_type="${3:-log}"
  shift 3

  if [ -z "$NGINX_LOG_FILE" ]; then
    return
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

# Print error and exit with code
die() {
  local msg="$1"
  local code="${2:-$ERR_UNKNOWN}"
  log "ERROR: $msg"
  log_json "ERROR" "$msg" "backup_error" "error_code=$code"
  echo "Error $code: $msg" >&2
  exit "$code"
}

# Logging function
log() {
  local msg="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [ -n "$LOG_FILE" ]; then
    echo "[$timestamp] $msg" >> "$LOG_FILE"
  fi
  # Also echo to stdout for non-error messages
  if [[ ! "$msg" =~ ^ERROR: ]]; then
    echo "$msg"
  fi

  # Determine log level
  local level="INFO"
  if [[ "$msg" =~ ^ERROR: ]]; then
    level="ERROR"
  elif [[ "$msg" =~ ^WARNING: ]]; then
    level="WARN"
  fi

  # Log to JSON (strip level prefix from message if present)
  local clean_msg="${msg#ERROR: }"
  clean_msg="${clean_msg#WARNING: }"
  log_json "$level" "$clean_msg" "backup_log"
}

# Cleanup function for trap
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Script failed with exit code $exit_code, cleaning up..."

    # Log failure event for New Relic
    if [ -n "$BACKUP_START_TIME" ]; then
      local failure_time=$(date +%s)
      local duration=$((failure_time - BACKUP_START_TIME))

      log_json "ERROR" "Backup failed" "backup_failed" \
        "backup_label=${BACKUP_LABEL:-unknown}" \
        "duration_seconds=$duration" \
        "exit_code=$exit_code" \
        "compression=${compression:-unknown}" \
        "status=failed"
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

# Function to parse INI-style config file
parse_config_file() {
  local config_path="$1"

  if [ ! -f "$config_path" ]; then
    die "Config file not found: $config_path" $ERR_USAGE
  fi

  log "Loading configuration from: $config_path"

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

      # Map config file keys to script variables
      case "$current_section" in
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
    fi
  done < "$config_path"
}

# Check for required external commands
for cmd in docker sed grep date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command '$cmd' not found in PATH. Please install it before running this script." $ERR_MISSING_CMD
  fi
done

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

  log "Available disk space in $target_dir: ${available_gb}GB"

  if [ "$available_gb" -lt "$min_free_gb" ]; then
    die "Insufficient disk space in $target_dir. Available: ${available_gb}GB, Required: at least ${min_free_gb}GB" $ERR_DISK_SPACE
  fi

  log "Disk space check passed"
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
    log "Querying PostgreSQL data directory size..."
    local volume_size_gb
    volume_size_gb=$(get_postgres_volume_size_gb)

    if [ "$volume_size_gb" -gt 0 ] 2>/dev/null; then
      required_space_gb=$((volume_size_gb + disk_space_margin_gb))
      log "PostgreSQL data directory size: ${volume_size_gb}GB"
      log "Calculated required disk space: ${volume_size_gb}GB (data directory) + ${disk_space_margin_gb}GB (margin) = ${required_space_gb}GB"
    else
      # Fallback to default if volume size query failed
      required_space_gb="5"
      log "WARNING: Failed to get data directory size, using default minimum disk space: ${required_space_gb}GB"
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

# Function to get database host from compose service
get_db_host_from_compose() {
  if [ -n "$db_host" ]; then
    echo "$db_host"
  else
    echo "$service"
  fi
}

# Function recreate compose network name
get_compose_network() {
  local folder_name
  folder_name=$(basename "$(dirname "$compose_filepath")")
  echo "${folder_name}_default"
}

# Function to create backup using database container
create_backup_from_db() {
  local backup_dir="$1"
  local host
  local compression_flag

  host=$(get_db_host_from_compose)
  compression_flag=$(get_compression_flag)

  log "Creating backup using database container"

  # Create temporary directory inside the db container
  log "Creating temporary directory in container"
  if ! docker compose -f "$compose_filepath" exec -T "$service" mkdir -p /tmp/backup; then
    die "Failed to create temporary directory in container" $ERR_BACKUP_FAILED
  fi

  # Run pg_basebackup inside the database container
  log "Running pg_basebackup..."
  if [ -n "${PGPASSWORD:-}" ]; then
    docker compose -f "$compose_filepath" exec -T "$service" \
      bash -c "PGPASSWORD='$PGPASSWORD' pg_basebackup -h $host -p $db_port -U $db_user -D /tmp/backup -Ft $compression_flag -P -v"
    local backup_exit_code=$?
  else
    docker compose -f "$compose_filepath" exec -T "$service" \
      pg_basebackup -h "$host" -p "$db_port" -U "$db_user" -D /tmp/backup -Ft $compression_flag -P -v
    local backup_exit_code=$?
  fi

  # Check if pg_basebackup failed
  if [ $backup_exit_code -ne 0 ]; then
    log "ERROR: pg_basebackup failed with exit code $backup_exit_code"
    log "Cleaning up failed backup attempt..."
    docker compose -f "$compose_filepath" exec -T "$service" rm -rf /tmp/backup 2>/dev/null || true
    die "Database backup failed - check database connection and credentials" $ERR_BACKUP_FAILED
  fi

  log "pg_basebackup completed successfully"

  # Copy backup files from container to host
  log "Copying backup files from container to host..."
  if ! docker compose -f "$compose_filepath" cp "$service":/tmp/backup/. "$backup_dir/"; then
    log "ERROR: Failed to copy backup files from container"
    docker compose -f "$compose_filepath" exec -T "$service" rm -rf /tmp/backup 2>/dev/null || true
    die "Failed to copy backup files from container to host" $ERR_BACKUP_FAILED
  fi

  # Cleanup temporary directory in container
  log "Cleaning up container temporary directory"
  if ! docker compose -f "$compose_filepath" exec -T "$service" rm -rf /tmp/backup; then
    log "WARNING: Failed to cleanup temporary directory in container"
  fi

  log "Backup files copied to $backup_dir"
  ls -lh "$backup_dir" | tee -a "$LOG_FILE"

  # Post-process with bzip2 if needed
  if [ "$compression" = "bzip2" ]; then
    log "Compressing backup files with bzip2..."
    for tarfile in "$backup_dir"/*.tar; do
      if [ -f "$tarfile" ]; then
        local filesize=$(du -h "$tarfile" | cut -f1)
        log "Compressing $(basename "$tarfile") ($filesize) - this may take several minutes..."

        # Use pv if available for progress, otherwise use plain bzip2
        local bz2_file="$tarfile.bz2"
        if command -v pv >/dev/null 2>&1; then
          if pv "$tarfile" | bzip2 -9 > "$bz2_file"; then
            log "Compression successful, removing original tar file"
            rm "$tarfile"
          else
            log "ERROR: bzip2 compression failed for $(basename "$tarfile"), keeping original"
            rm -f "$bz2_file"  # Remove partial bz2 file
            die "Compression failed for $(basename "$tarfile")" $ERR_BACKUP_FAILED
          fi
        else
          if bzip2 -9 -v "$tarfile"; then
            log "Compression successful"
          else
            log "ERROR: bzip2 compression failed for $(basename "$tarfile")"
            die "Compression failed for $(basename "$tarfile")" $ERR_BACKUP_FAILED
          fi
        fi
      fi
    done
    log "Compression completed"
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

  log "Uploading backup to S3: s3://$bucket/$s3_path/"
  log "Using S3 prefix: $s3_backup_prefix"

  # Count files to upload
  local file_count
  file_count=$(find "$backup_dir" -type f | wc -l)
  log "Files to upload: $file_count"

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

  log "S3 upload completed successfully"
}

# Function to generate checksums for backup files
generate_checksums() {
  local backup_dir="$1"
  local label="$2"
  local checksum_file="$backup_dir/backup.sha256"
  local metadata_file="$backup_dir/backup.sha256.info"

  log "Generating SHA256 checksums for backup integrity verification..."

  # Generate checksums for all files (excluding checksum/metadata files themselves)
  (cd "$backup_dir" && find . -type f ! -name "backup.sha256*" -exec sha256sum {} \; | sort -k2) > "$checksum_file"

  local file_count
  file_count=$(wc -l < "$checksum_file")

  log "Generated checksums for $file_count files"
  log "Checksum manifest: $checksum_file"

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

  log "Generated checksum metadata: $metadata_file"

  # Log first few checksums for debugging
  log "Sample checksums:"
  head -n 3 "$checksum_file" | while read -r line; do
    log "  $line"
  done

  log_json "INFO" "Checksums generated" "backup_checksum" \
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
    log "No retention policy configured, skipping cleanup"
    return 0
  fi

  log "Applying retention policy to S3 backups..."

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
    log "WARNING: Failed to list backups for retention cleanup"
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
    log "WARNING: Failed to process backup list for retention"
    return 0
  }

  # Delete old backups
  if [ -z "$backup_dirs" ]; then
    log "No old backups to delete (retention policy satisfied)"
    return 0
  fi

  local delete_count=0
  while IFS= read -r backup_dir; do
    [ -z "$backup_dir" ] && continue

    log "Deleting old backup: s3://$bucket/$backup_dir/"

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
      log_json "INFO" "Deleted old backup: $backup_dir" "backup_retention" "backup_dir=$backup_dir"
    else
      log "WARNING: Failed to delete backup: $backup_dir"
    fi
  done <<< "$backup_dirs"

  if [ $delete_count -gt 0 ]; then
    log "Retention policy: deleted $delete_count old backup(s)"
    log_json "INFO" "Retention cleanup completed" "backup_retention" "deleted_count=$delete_count"
  fi
}

# Function to run backup with S3 storage
run_backup_s3() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
  generate_checksums "$backup_dir" "$label"
  upload_backup_to_s3 "$backup_dir" "$label"
  log "Checksum manifest uploaded to S3 for external verification"
  cleanup_old_backups
}

# Function to run backup with local storage
run_backup_local() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
  generate_checksums "$backup_dir" "$label"
  log "Local backup complete with checksum manifest:"
  log "  - Checksums: $backup_dir/backup.sha256"
  log "  - Metadata: $backup_dir/backup.sha256.info"
}

# Main backup orchestration function
run_backup() {
  local label
  local abs_backup_path

  label=$(generate_backup_label)
  BACKUP_LABEL="$label"  # Store globally for error logging

  log "Starting backup from $(get_db_host_from_compose):$db_port as user $db_user"
  log "Backup label: $label"
  log "Compression: $compression"

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
  local file_count=$(find "$abs_backup_path/$label" -type f | wc -l)

  # Cleanup temporary directory if used for S3 (explicit check)
  if [ -n "$s3_url" ] && [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
    log "Cleaning up temporary backup directory: $TEMP_BACKUP_DIR"
    rm -rf "$TEMP_BACKUP_DIR"
    TEMP_BACKUP_DIR=""  # Clear to avoid double cleanup in trap
  fi

  log "Backup completed successfully"
  log "Backup size: ${backup_size_mb}MB, Files: $file_count, Duration: ${duration}s"

  # Determine destination
  local destination
  if [ -n "$backup_path" ]; then
    destination="local:$backup_path/$label"
    log "Backup location: $backup_path/$label"
  else
    destination="s3:$s3_url/$label"
    log "Backup uploaded to: $s3_url/$label"
  fi

  # Log structured completion event for New Relic
  log_json "INFO" "Backup completed successfully" "backup_completed" \
    "backup_label=$label" \
    "duration_seconds=$duration" \
    "backup_size_mb=$backup_size_mb" \
    "backup_size_bytes=$backup_size_bytes" \
    "file_count=$file_count" \
    "compression=$compression" \
    "destination=$destination" \
    "db_host=$(get_db_host_from_compose)" \
    "db_port=$db_port" \
    "db_user=$db_user" \
    "status=success"
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
  parse_config_file "$config_file"
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

# Initialize log files
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Human-readable log with timestamp in filename (for history)
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%dT%H%M%S).log"

# nginx format log with consistent name (for New Relic to monitor)
NGINX_LOG_FILE="$LOG_DIR/backup.log"

# Record start time for metrics
BACKUP_START_TIME=$(date +%s)

log "=== Backup script started ==="
log "Log file: $LOG_FILE"
log "nginx log file: $NGINX_LOG_FILE"

# Log start event with metadata
log_json "INFO" "Backup started" "backup_started" \
  "backup_type=pg_basebackup" \
  "compression=$compression"

# Validate arguments
check_args

# Execute backup
run_backup

# Log completion
log "=== Backup script completed successfully ==="
