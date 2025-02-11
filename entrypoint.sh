#!/bin/bash

# Check if $backup_path is provide
if [ -z "$backup_path" ]; then
  echo "running in local_backup mode"
else  
  # Configure AWS credentials
  aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
  aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
  aws configure set default.region ${AWS_DEFAULT_REGION}
  # Download backup from S3
  aws s3 cp ${S3_BACKUP_URL} /backup/ --recursive --endpoint ${S3_ENDPOINT}
fi


# Clean the volume
rm -rf /data/*
# Restore base.tar.gz in data
tar -zxf /backup/base.tar.gz -C /data/
# Restore wal
tar -zxf /backup/pg_wal.tar.gz -C /data/pg_wal/
# Create recovery.signal
touch /data/recovery.signal
# Change owner in volume
chown -R 999:999 /data

# Ensure 'restore_command' is set.
result=$(sed -n "/^restore_command/p" /data/postgresql.conf)  # check if there is already a restore_command

if [[ -z $result ]]; then  # Ensure that result was empty (no command found)
  sed -i "s/^#restore_command = ''/restore_command = 'cp \/var\/lib\/postgresql\/pg_wal\/%f %p'/" /data/postgresql.conf
fi
