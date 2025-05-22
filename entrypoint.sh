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
echo "Cleaning /data volume..."
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
  tar -jxvf /backup/data.tar.bz2 -C /data/

  echo "" > /data/custom.conf
  echo "" > /data/override.conf
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
  echo "Running in local_backup mode"
  # You may want to add local WAL extraction here if needed
else
  echo "Running in aws mode"
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"

  bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"

  key=$(aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --endpoint "$S3_ENDPOINT" \
    --prefix postgresql-cluster/base/ \
    --region "$AWS_DEFAULT_REGION" \
    --output text \
    --query "reverse(sort_by(Contents,&LastModified))[0].Key")

  folder="${key%/*}/"
  s3_full_url="${S3_BACKUP_URL}/${folder}"
  echo "$s3_full_url"

  aws s3 cp "$s3_full_url" /backup/ --endpoint "$S3_ENDPOINT" --recursive

  info="/backup/backup.info"
  fetch_wals "$info" "$bucket"
fi

restore_backup
set_restore_command
