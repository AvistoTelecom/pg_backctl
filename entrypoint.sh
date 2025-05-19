#!/bin/bash

# Clean the volume
rm -rf /data/*

# Check if $backup_path is provide
if [ -n "$backup_path" ]; then
  echo "Running in local_backup mode"
 else
  echo "running in aws mode"
  # Configure AWS credentials
  aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
  aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
  aws configure set default.region ${AWS_DEFAULT_REGION}
  
  # Get bucket name from s3 url
  bucket="${S3_BACKUP_URL#s3://}"
  bucket="${bucket%/}"
  
  # Get latest base backup directory
  # TODO add --prefix in odo args
  key=$(aws s3api list-objects-v2 \
  --bucket ${bucket} \
  --endpoint ${S3_ENDPOINT} \
  --prefix postgresql-cluster/base/ \
  --region ${AWS_DEFAULT_REGION} \
  --output text \
  --query "reverse(sort_by(Contents,&LastModified))[0].Key")

  # Clean the returned key to get the folder
  folder="${key%/*}/"
  s3_full_url=${S3_BACKUP_URL}/${folder}
  echo $s3_full_url

  # Get content of the latest base backup
  aws s3 cp ${S3_BACKUP_URL}/${folder} /backup/ --endpoint ${S3_ENDPOINT} --recursive

  # ==== MEP patch because it's fun ====
  # Get all required wals for the restoration de ses grands morts
  info="/backup/backup.info"


  # Get start and end wals
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

  # Generate file idexes from start to end (included)
  for i in $(seq $start_dec $end_dec); do
    # decimal to hex
    seg_hex=$(printf "%08X" "$i")
    file_key="${prefix}${seg_hex}.bz2"

    echo "-> fetch $file_key"

    # Get full path
    key=$(aws s3api list-objects-v2 \
          --bucket ${bucket} \
          --endpoint ${S3_ENDPOINT} \
          --prefix "postgresql-cluster/wals/${prefix}/" \
          --query "Contents[?ends_with(Key, '$file_key')].Key | [0]" \
          --output text)

    if [[ $key != "None" ]]; then
      echo "  found at $key"

      aws s3 cp s3://${bucket}/${key} /backup/wals --endpoint ${S3_ENDPOINT}

      echo "   decompressing /backup/wals/${file_key} -> /data/pg_wal/${file_key%.bz2}"
      bzip2 -dc "/backup/wals/$file_key" > "/data/pg_wal/${file_key%.bz2}"
    else
      echo "  could not find $file_key ($key)"
    fi

  done

fi

# Restore base.tar.gz in data
tar -jxvf /backup/data.tar.bz2 -C /data/
echo "" > /data/custom.conf
echo "" > /data/override.conf
# Create recovery.signal
touch /data/recovery.signal

# Change owner in volume
chown -R 999:999 /data

# Ensure 'restore_command' is set.
result=$(sed -n "/^restore_command/p" /data/postgresql.conf)  # check if there is already a restore_command

if [[ -z $result ]]; then  # Ensure that result was empty (no command found)
  sed -i "s/^#restore_command = ''/restore_command = 'cp \/var\/lib\/postgresql\/data\/pg_wal\/%f %p'/" /data/postgresql.conf
fi
