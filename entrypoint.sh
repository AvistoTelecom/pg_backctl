#!/bin/bash

set -euo pipefail

# Get script directory and source shared libraries
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "$SCRIPT_DIR/lib/error_codes.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker_utils.sh"

# Set up logging context
SCRIPT_NAME="pg_backctl_restore"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Unified log file for all pg_backctl scripts
LOG_FILE="$LOG_DIR/pg_backctl.log"

# Rotate logs before starting (keep last 5 logs)
rotate_logs "$LOG_FILE" 5

# Check for required commands
check_required_commands aws bzip2 tar grep sed

# Clean the volume
log_simple "Cleaning /data volume..." \
  "event=volume_cleanup_start" \
  "target_volume=/data"
rm -rf /data/*
log_simple "Volume cleaned" \
  "event=volume_cleanup_completed"

fetch_wals() {
  local info="$1"
  local bucket="$2"
  local prefix start_hex end_hex start_dec end_dec begin_wal end_wal

  begin_wal=$(grep '^begin_wal=' "$info" | cut -d= -f2)
  end_wal=$(grep '^end_wal=' "$info" | cut -d= -f2)

  echo "Requires wals from $begin_wal to $end_wal"

  prefix=${begin_wal:0:16}
  start_hex=${begin_wal:16}
  end_hex=${end_wal:16}
  start_dec=$((16#$start_hex))
  end_dec=$((16#$end_hex))

  echo "Decimal indexes: $start_dec, $end_dec"

  mkdir -p /data/pg_wal /backup/wals

  for i in $(seq $start_dec $end_dec); do
    seg_hex=$(printf "%08X" "$i")
    file_key="${prefix}${seg_hex}.bz2"
    echo "-> fetch $file_key"
    key=$(aws s3api list-objects-v2 \
          --bucket "$bucket" \
          --endpoint "$S3_ENDPOINT" \
          --prefix "postgresql-cluster/wals/${prefix}/" \
          --query "Contents[?ends_with(Key, '$file_key')].Key | [0]" \
          --output text)
    if [[ "$key" != "None" ]]; then
      echo "  found at $key"
      aws s3 cp "s3://$bucket/$key" /backup/wals --endpoint "$S3_ENDPOINT"
      echo "   decompressing /backup/wals/${file_key} -> /data/pg_wal/${file_key%.bz2}"
      bzip2 -dc "/backup/wals/$file_key" > "/data/pg_wal/${file_key%.bz2}"
    else
      echo "  could not find $file_key ($key)"
    fi
  done
}

restore_backup() {
  log_simple "Restoring base backup..." \
    "event=restore_start"

  # Check which backup format we have
  if [ -f /backup/data.tar.bz2 ]; then
    # Old format (other tools)
    log_simple "Restoring from data.tar.bz2 format..." \
      "event=restore_format_detected" \
      "format=legacy_data_tar_bz2"
    tar -jxvf /backup/data.tar.bz2 -C /data/
  elif [ -f /backup/base.tar.gz ]; then
    # pg_backctl format
    log_simple "Restoring from pg_basebackup format (base.tar.gz + pg_wal.tar.gz)..." \
      "event=restore_format_detected" \
      "format=pg_backctl_gzip"
    tar -zxvf /backup/base.tar.gz -C /data/

    # Check if pg_wal exists separately
    if [ -f /backup/pg_wal.tar.gz ]; then
      log_simple "Extracting pg_wal.tar.gz..." \
        "event=wal_extraction_start"
      tar -zxvf /backup/pg_wal.tar.gz -C /data/pg_wal/
    fi
  elif [ -f /backup/base.tar.bz2 ]; then
    # pg_backctl format with bzip2
    log_simple "Restoring from pg_basebackup format (base.tar.bz2 + pg_wal.tar.bz2)..." \
      "event=restore_format_detected" \
      "format=pg_backctl_bzip2"
    tar -jxvf /backup/base.tar.bz2 -C /data/

    # Check if pg_wal exists separately
    if [ -f /backup/pg_wal.tar.bz2 ]; then
      log_simple "Extracting pg_wal.tar.bz2..." \
        "event=wal_extraction_start"
      tar -jxvf /backup/pg_wal.tar.bz2 -C /data/pg_wal/
    fi
  else
    ls -lah /backup/
    die "No recognized backup format found!" $ERR_RESTORE_FAILED
  fi

  log_simple "Creating recovery.signal..." \
    "event=recovery_signal_created"
  touch /data/recovery.signal
  chown -R 999:999 /data

  log_simple "Restore completed" \
    "event=restore_completed"
}

set_restore_command() {
  local conf_file="/data/postgresql.conf"
  local result
  result=$(sed -n "/^restore_command/p" "$conf_file" || true)
  if [[ -z "$result" ]]; then
    sed -i "s|^#restore_command = ''|restore_command = 'cp /var/lib/postgresql/data/pg_wal/%f %p'|" "$conf_file"
  fi
}

# Main logic
if [[ -n "${backup_path:-}" ]]; then
  log_simple "Local backup mode" \
    "event=restore_mode" \
    "mode=local" \
    "backup_path=${backup_path:-}"
  # You may want to add local WAL extraction here if needed
else
  log_simple "Configuring S3 mode" \
    "event=restore_mode" \
    "mode=s3"
  log_simple "S3 configuration" \
    "event=s3_config" \
    "s3_url=${S3_BACKUP_URL}" \
    "s3_endpoint=${S3_ENDPOINT}" \
    "aws_region=${AWS_DEFAULT_REGION}"

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"

  log_simple "Parsed bucket: ${bucket}" \
    "event=s3_bucket_parsed" \
    "bucket=$bucket"

  # Use S3_BACKUP_PATH if provided, otherwise auto-detect (backward compatible)
  if [ -n "${S3_BACKUP_PATH:-}" ]; then
    log_simple "Using specified backup path: $S3_BACKUP_PATH" \
      "event=backup_path_mode" \
      "mode=specific" \
      "s3_backup_path=$S3_BACKUP_PATH"
    s3_full_url="s3://${bucket}/${S3_BACKUP_PATH}/"
  else
    log_simple "Auto-detecting latest backup" \
      "event=backup_path_mode" \
      "mode=auto_detect"
    # Default to postgresql-cluster/base/ for backward compatibility
    search_prefix="${S3_SEARCH_PREFIX:-postgresql-cluster/base/}"

    # Treat "/" as root level (empty prefix)
    if [ "$search_prefix" = "/" ]; then
      search_prefix=""
      log_simple "Searching at bucket root level" \
        "event=s3_search_prefix" \
        "prefix=root"
    fi

    log_simple "Searching for latest backup" \
      "event=s3_search_start" \
      "bucket=s3://${bucket}/" \
      "search_prefix=${search_prefix:-root}" \
      "endpoint=${S3_ENDPOINT}"

    # Use json output to avoid sort_by error on empty results
    key=$(aws s3api list-objects-v2 \
      --bucket "$bucket" \
      --endpoint "$S3_ENDPOINT" \
      --prefix "$search_prefix" \
      --region "$AWS_DEFAULT_REGION" \
      --output json \
      --query "reverse(sort_by(Contents || \`[]\`,&LastModified))[0].Key" | tr -d '"')

    if [ -z "$key" ] || [ "$key" = "null" ] || [ "$key" = "None" ]; then
      log_simple "Available prefixes in bucket:" \
        "event=s3_list_available"
      aws s3 ls "s3://${bucket}/" --endpoint "$S3_ENDPOINT" || echo "Failed to list bucket contents"
      die "No backups found in s3://${bucket}/${search_prefix}" $ERR_RESTORE_FAILED
    fi

    folder="${key%/*}/"
    s3_full_url="s3://${bucket}/${folder}"
    log_simple "Found latest backup: $s3_full_url" \
      "event=s3_backup_found" \
      "s3_backup_url=$s3_full_url"
  fi

  log_simple "Downloading backup from S3" \
    "event=s3_download_start" \
    "s3_url=$s3_full_url" \
    "endpoint=$S3_ENDPOINT" \
    "region=$AWS_DEFAULT_REGION"

  aws s3 cp "$s3_full_url" /backup/ --endpoint "$S3_ENDPOINT" --recursive

  log_simple "Download completed successfully" \
    "event=s3_download_completed"

  # Check if backup.info exists (for WAL archiving backups)
  info="/backup/backup.info"
  if [ -f "$info" ]; then
    log_simple "Found backup.info, fetching WAL files..." \
      "event=wal_fetch_start" \
      "backup_info_found=true"
    fetch_wals "$info" "$bucket"
  else
    log_simple "No backup.info found (pg_basebackup format - WAL files included in backup)" \
      "event=wal_info_check" \
      "backup_info_found=false"
  fi
fi

restore_backup
set_restore_command

log_simple "Restore operation completed successfully" \
  "event=restore_operation_completed"
