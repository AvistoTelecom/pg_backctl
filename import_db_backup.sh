#!/bin/bash

#Down container
docker compose down $service
#run side container --rm + mount volume
docker run -d --rm -v $volume_name:/data odo:0.1
#Up container
#promote master
docker exec -it -u postgres $CONTAINER_NAME bash -c "pg_ctl promote"
#alter config