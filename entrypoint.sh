#!/bin/bash

set -euo pipefail

# Check for required commands
for cmd in aws bzip2 tar grep sed; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' not found in PATH. Please install it before running this script." >&2
    exit 10
  fi
done

# Clean the volume
echo "[pg_backctl] Cleaning /data volume..."
rm -rf /data/*

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
  echo "Restoring base backup..."

  # Check which backup format we have
  if [ -f /backup/data.tar.bz2 ]; then
    # Old format (other tools)
    echo "[pg_backctl] Restoring from data.tar.bz2 format..."
    tar -jxvf /backup/data.tar.bz2 -C /data/
  elif [ -f /backup/base.tar.gz ]; then
    # pg_backctl format
    echo "[pg_backctl] Restoring from pg_basebackup format (base.tar.gz + pg_wal.tar.gz)..."
    tar -zxvf /backup/base.tar.gz -C /data/

    # Check if pg_wal exists separately
    if [ -f /backup/pg_wal.tar.gz ]; then
      echo "[pg_backctl] Extracting pg_wal.tar.gz..."
      tar -zxvf /backup/pg_wal.tar.gz -C /data/pg_wal/
    fi
  elif [ -f /backup/base.tar.bz2 ]; then
    # pg_backctl format with bzip2
    echo "[pg_backctl] Restoring from pg_basebackup format (base.tar.bz2 + pg_wal.tar.bz2)..."
    tar -jxvf /backup/base.tar.bz2 -C /data/

    # Check if pg_wal exists separately
    if [ -f /backup/pg_wal.tar.bz2 ]; then
      echo "[pg_backctl] Extracting pg_wal.tar.bz2..."
      tar -jxvf /backup/pg_wal.tar.bz2 -C /data/pg_wal/
    fi
  else
    echo "[pg_backctl] ERROR: No recognized backup format found!"
    ls -lah /backup/
    exit 1
  fi

  touch /data/recovery.signal
  chown -R 999:999 /data
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
  echo "[pg_backctl] local_backup mode"
  # You may want to add local WAL extraction here if needed
else
  echo "[pg_backctl] Configuring S3 mode"
  echo "[pg_backctl] S3_BACKUP_URL: ${S3_BACKUP_URL}"
  echo "[pg_backctl] S3_ENDPOINT: ${S3_ENDPOINT}"
  echo "[pg_backctl] AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"

  echo "[pg_backctl] Parsed bucket: ${bucket}"

  # Use S3_BACKUP_PATH if provided, otherwise auto-detect (backward compatible)
  if [ -n "${S3_BACKUP_PATH:-}" ]; then
    echo "[pg_backctl] Using specified backup path: $S3_BACKUP_PATH"
    s3_full_url="s3://${bucket}/${S3_BACKUP_PATH}/"
  else
    echo "[pg_backctl] Auto-detecting latest backup (using postgresql-cluster/base/ prefix for backward compatibility)"
    # Default to postgresql-cluster/base/ for backward compatibility
    search_prefix="${S3_SEARCH_PREFIX:-postgresql-cluster/base/}"

    # Treat "/" as root level (empty prefix)
    if [ "$search_prefix" = "/" ]; then
      search_prefix=""
      echo "[pg_backctl] Searching at bucket root level"
    fi

    echo "[pg_backctl] ========================================="
    echo "[pg_backctl] Searching for latest backup"
    echo "[pg_backctl] Bucket: s3://${bucket}/"
    if [ -n "$search_prefix" ]; then
      echo "[pg_backctl] Search prefix: ${search_prefix}"
      echo "[pg_backctl] Full search path: s3://${bucket}/${search_prefix}"
    else
      echo "[pg_backctl] Search prefix: (root level)"
      echo "[pg_backctl] Full search path: s3://${bucket}/"
    fi
    echo "[pg_backctl] Endpoint: ${S3_ENDPOINT}"
    echo "[pg_backctl] ========================================="

    # Use json output to avoid sort_by error on empty results
    key=$(aws s3api list-objects-v2 \
      --bucket "$bucket" \
      --endpoint "$S3_ENDPOINT" \
      --prefix "$search_prefix" \
      --region "$AWS_DEFAULT_REGION" \
      --output json \
      --query "reverse(sort_by(Contents || \`[]\`,&LastModified))[0].Key" | tr -d '"')

    if [ -z "$key" ] || [ "$key" = "null" ] || [ "$key" = "None" ]; then
      echo "[pg_backctl] ERROR: No backups found in s3://${bucket}/${search_prefix}"
      echo "[pg_backctl] Available prefixes in bucket:"
      aws s3 ls "s3://${bucket}/" --endpoint "$S3_ENDPOINT" || echo "Failed to list bucket contents"
      exit 1
    fi

    folder="${key%/*}/"
    s3_full_url="s3://${bucket}/${folder}"
    echo "[pg_backctl] Found latest backup: $s3_full_url"
  fi

  echo "[pg_backctl] ========================================="
  echo "[pg_backctl] Downloading backup from S3"
  echo "[pg_backctl] URL: $s3_full_url"
  echo "[pg_backctl] Endpoint: $S3_ENDPOINT"
  echo "[pg_backctl] Region: $AWS_DEFAULT_REGION"
  echo "[pg_backctl] ========================================="

  aws s3 cp "$s3_full_url" /backup/ --endpoint "$S3_ENDPOINT" --recursive

  echo "[pg_backctl] Download completed successfully"

  # Check if backup.info exists (for WAL archiving backups)
  info="/backup/backup.info"
  if [ -f "$info" ]; then
    echo "[pg_backctl] Found backup.info, fetching WAL files..."
    fetch_wals "$info" "$bucket"
  else
    echo "[pg_backctl] No backup.info found (pg_basebackup format - WAL files included in backup)"
  fi
fi

restore_backup
set_restore_command
