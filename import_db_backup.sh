#!/bin/bash
replace_conf=false
# Parse command line arguments
while getopts "a:s:r:u:v:n:f:c:" opt; do
  case $opt in
    a) aws_access_key="$OPTARG";;
    s) aws_secret_key="$OPTARG";;
    r) aws_region="$OPTARG";;
    u) s3_url="$OPTARG";;
    v) volume_name="$OPTARG";;
    n) service="$OPTARG";;
    f) compose_filepath="$OPTARG";;
    c) replace_conf="$OPTARG";;
    ?) echo "Usage: $0 -a AWS_ACCESS_KEY -s AWS_SECRET_KEY -r AWS_REGION -u S3_BACKUP_URL -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH -c REPLACE_CONF" >&2
       exit 1;;
  esac
done

# Verify all required arguments are provided
if [ -z "$aws_access_key" ] || [ -z "$aws_secret_key" ] || [ -z "$aws_region" ] || [ -z "$s3_url" ] || [ -z "$volume_name" ] || [ -z "$service" ] || [ -z "$compose_filepath" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -a AWS_ACCESS_KEY -s AWS_SECRET_KEY -r AWS_REGION -u S3_BACKUP_URL -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH"
    exit 1
fi
# Check if replace_conf is true and postgresql.auto.conf is provided
if $replace_conf; then
    if [ -f ./confs/postgresql.auto.conf]; then
      pass
    else
      echo "option -c to replace config is set to true but postgresql.auto.conf is missing"
      exit 3
  fi
fi

# Down container
docker compose -f $compose_filepath down $service

# Run side container --rm + mount volume
# Odo handles the restoration of the backup
docker run -d --rm \
  -e AWS_ACCESS_KEY_ID=$aws_access_key \
  -e AWS_SECRET_ACCESS_KEY=$aws_secret_key \
  -e AWS_DEFAULT_REGION=$aws_region \
  -e S3_BACKUP_URL=$s3_url \
  -v $volume_name:/data odo:0.1

# Up container
docker compose -f $compose_filepath up -d $service

# Promote master
docker exec -it -u postgres $CONTAINER_NAME bash -c "pg_ctl promote"
# Check if replace_conf == true
if $replace_conf; then
  # Alter config
  docker cp ./confs/postgresql.auto.conf $container_name:/var/lib/postgresql/data/postgresql.auto.conf
  # restart container
  docker compose -f $compose_filepath restart -d $service
fi