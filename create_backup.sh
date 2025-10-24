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
JSON_LOG_FILE=""
BACKUP_START_TIME=""
BACKUP_LABEL=""

# Escape JSON strings
json_escape() {
  local string="$1"
  # Escape backslashes, quotes, and newlines
  echo "$string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

# JSON logging function for New Relic
log_json() {
  local level="$1"
  local message="$2"
  local event_type="${3:-log}"
  shift 3

  if [ -z "$JSON_LOG_FILE" ]; then
    return
  fi

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')

  # Build JSON object
  local json_msg=$(json_escape "$message")
  local json_obj="{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$json_msg\",\"event_type\":\"$event_type\""

  # Add service metadata
  json_obj="$json_obj,\"service.name\":\"pg_backctl\",\"hostname\":\"$(hostname)\""

  # Add additional fields passed as key=value pairs
  while [ $# -gt 0 ]; do
    local key="${1%%=*}"
    local value="${1#*=}"
    local escaped_value=$(json_escape "$value")
    json_obj="$json_obj,\"$key\":\"$escaped_value\""
    shift
  done

  json_obj="$json_obj}"

  echo "$json_obj" >> "$JSON_LOG_FILE"
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
odo_image="odo:latest"

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
  Database connection:
  -n SERVICE_NAME       Docker Compose service name (required)
  -f COMPOSE_FILEPATH   Path to docker-compose file (required)
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
  -O ODO_IMAGE          ODO docker image (default: odo:latest)
  -p PG_VERSION         Postgres version (default: latest)

  AWS credentials (optional, can be set in .env):
  -a AWS_ACCESS_KEY     AWS access key
  -s AWS_SECRET_KEY     AWS secret key
  -r AWS_REGION         AWS region

  -h, --help            Show this help message and exit

Examples:
  # Backup to S3 with gzip compression
  $0 -n db-service -f docker-compose.yml -u s3://mybucket/backups -e https://s3.endpoint.com

  # Backup to local directory with bzip2 compression
  $0 -n db-service -f docker-compose.yml -P /backups/mydb -C bzip2

  # Backup with custom label
  $0 -n db-service -f docker-compose.yml -P /backups/mydb -l "pre-migration-backup"

  # Backup with custom database connection
  $0 -n db-service -f docker-compose.yml -H localhost -T 5432 -U replication -P /backups/mydb
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

  # If local, ensure directory exists or can be created
  if [ -n "${backup_path:-}" ]; then
    mkdir -p "$backup_path" || die "Cannot create backup directory: $backup_path" $ERR_USAGE
    # Check disk space for local backups
    check_disk_space "$backup_path"
  else
    # For S3 mode, check /tmp disk space
    check_disk_space "/tmp"
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
  docker compose -f "$compose_filepath" exec -T "$service" mkdir -p /tmp/backup

  # Run pg_basebackup inside the database container
  log "Running pg_basebackup..."
  if [ -n "${PGPASSWORD:-}" ]; then
    docker compose -f "$compose_filepath" exec -T "$service" \
      bash -c "PGPASSWORD='$PGPASSWORD' pg_basebackup -h $host -p $db_port -U $db_user -D /tmp/backup -Ft $compression_flag -P -v"
  else
    docker compose -f "$compose_filepath" exec -T "$service" \
      pg_basebackup -h "$host" -p "$db_port" -U "$db_user" -D /tmp/backup -Ft $compression_flag -P -v
  fi

  # Copy backup files from container to host
  log "Copying backup files from container to host..."
  docker compose -f "$compose_filepath" cp "$service":/tmp/backup/. "$backup_dir/"

  # Cleanup temporary directory in container
  log "Cleaning up container temporary directory"
  docker compose -f "$compose_filepath" exec -T "$service" rm -rf /tmp/backup

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

# Function to upload backup to S3 using ODO image
upload_backup_to_s3() {
  local backup_dir="$1"
  local label="$2"
  local bucket="${s3_url#s3://}"
  bucket="${bucket%/}"

  log "Uploading backup to S3: s3://$bucket/$label/"

  # Count files to upload for verification
  local file_count
  file_count=$(find "$backup_dir" -type f | wc -l)
  log "Files to upload: $file_count"

  # Run docker with explicit error handling
  if ! docker run -t --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -e BACKUP_LABEL="$label" \
    -e S3_BUCKET="$bucket" \
    -v "$backup_dir":/backup \
    --entrypoint bash \
    "$odo_image" \
    -c "set -e && \
        aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" && \
        aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" && \
        aws configure set default.region \"\$AWS_DEFAULT_REGION\" && \
        echo 'Starting S3 upload...' && \
        aws s3 cp /backup/ \"s3://\$S3_BUCKET/\$BACKUP_LABEL/\" --recursive --endpoint-url \"\$S3_ENDPOINT\" && \
        echo 'Verifying upload...' && \
        uploaded_count=\$(aws s3 ls \"s3://\$S3_BUCKET/\$BACKUP_LABEL/\" --endpoint-url \"\$S3_ENDPOINT\" --recursive | wc -l) && \
        echo \"Uploaded files: \$uploaded_count\" && \
        echo \"Upload completed to s3://\$S3_BUCKET/\$BACKUP_LABEL/\""; then
    die "S3 upload failed. Check AWS credentials, endpoint, and network connectivity." $ERR_BACKUP_FAILED
  fi

  log "S3 upload completed successfully"
}

# Function to run backup with S3 storage
run_backup_s3() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
  upload_backup_to_s3 "$backup_dir" "$label"
}

# Function to run backup with local storage
run_backup_local() {
  local backup_dir="$1"
  local label="$2"

  create_backup_from_db "$backup_dir"
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

# Robust env loading
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Parse command line arguments
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
    -O) odo_image="$2"; shift 2;;
    -p) pgversion="$2"; shift 2;;
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

# JSON log with consistent name (for New Relic to monitor)
JSON_LOG_FILE="$LOG_DIR/backup.json"

# Record start time for metrics
BACKUP_START_TIME=$(date +%s)

log "=== Backup script started ==="
log "Log file: $LOG_FILE"
log "JSON log file: $JSON_LOG_FILE"

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
