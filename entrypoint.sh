#!/bin/bash
## Grab latest backup

#clean the volumes
rm -rf /data/*
#Restore base.tar.gz in data
sudo tar -zxf base.tar.gz -C /data/
#Restore wal
sudo tar -zxf pg_wal.tar.gz -C /data/pg_wal/
#create recovery.signal
sudo touch /data/recovery.signal
#change owner in volume
sudo chown -R 999:999 /data