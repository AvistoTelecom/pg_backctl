#!/bin/bash

# Configure AWS credentials
aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
aws configure set default.region ${AWS_DEFAULT_REGION}

# Download backup from S3
aws s3 cp ${S3_BACKUP_URL} .

# Clean the volume
rm -rf /data/*
# Restore base.tar.gz in data
sudo tar -zxf base.tar.gz -C /data/
# Restore wal
sudo tar -zxf pg_wal.tar.gz -C /data/pg_wal/
# Create recovery.signal
sudo touch /data/recovery.signal
# Change owner in volume
sudo chown -R 999:999 /data