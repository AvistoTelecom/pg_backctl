## Install python If exsite

## Install fucking binary AWS CLI If existe

## Grab latest backup

#down the database
docker compose down
#clean the volumes
rm -rf data/*
#Restore base.tar.gz in data
sudo tar -zxf base.tar.gz -C data/
#Restore wal
sudo tar -zxf pg_wal.tar.gz -C data/pg_wal/
#create recovery.signal
sudo touch data/recovery.signal
#change owner in volume
sudo chown -R 999:999 data/
#Up database
docker compose up -d
#promote server
docker exec -it -u postgres db bash -c "pg_ctl promote"
## Alter configs

```