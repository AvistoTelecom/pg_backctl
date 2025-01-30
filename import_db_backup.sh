#!/bin/bash
replace_conf=false
override_volume=false
replace_conf=false
# Parse command line arguments
while getopts "a:s:r:u:e:v:n:f:coV:" opt; do
  case $opt in
    a) aws_access_key="$OPTARG";;
    s) aws_secret_key="$OPTARG";;
    r) aws_region="$OPTARG";;
    u) s3_url="$OPTARG";;
    e) s3_endpoint="$OPTARG";;
    v) volume_name="$OPTARG";;
    n) service="$OPTARG";;
    f) compose_filepath="$OPTARG";;
    c) replace_conf=true;;
    o) override_volume=true;;
    V) new_volume_name="$OPTARG";;
    ?) echo "Usage: $0 -a AWS_ACCESS_KEY -s AWS_SECRET_KEY -r AWS_REGION -u S3_BACKUP_URL -e S3_ENDPOINT -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH -c REPLACE_CONF" >&2
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
    echo "REPLACE CONF"
    if [ ! -e ./confs/postgresql.auto.conf ]; then
      echo "option -c to replace config is set to true but postgresql.auto.conf is missing"
      exit 3
  fi
fi

if [ $override_volume = false ] && [ -z "$new_volume_name" ]; then
  echo "You need to specify a new_volume_name using -V or use -o to override"
  exit 4
fi

# Down container
echo "Downing $service"
docker compose -f $compose_filepath down $service

if $override_volume; then
  # Run side container --rm + mount volume
  # Odo handles the restoration of the backup
  docker run -t --rm \
    -e AWS_ACCESS_KEY_ID=$aws_access_key \
    -e AWS_SECRET_ACCESS_KEY=$aws_secret_key \
    -e AWS_DEFAULT_REGION=$aws_region \
    -e S3_BACKUP_URL=$s3_url \
    -e S3_ENDPOINT=$s3_endpoint \
    -v $volume_name:/data odo:0.2
else
  echo "Creating new volume: $new_volume_name"
  echo "running sed"
  sed -i.bak "s/$volume_name/$new_volume_name/g" $compose_filepath
  docker compose -f $compose_filepath up -d $service
  docker compose -f $compose_filepath down $service
  # Get compose folder prefix and add it to new_volume_name
  folder_name=$(echo "$compose_filepath" | sed -E 's/.*\/(\w+)\/[^\/]*\.ya?ml$/\1/')
  echo "folder_name=$folder_name"
  new_compose_vol_name=${folder_name}_${new_volume_name}
  echo "new_compose_vol_name=$new_compose_vol_name"
  # Run side container --rm + mount volume
  # Odo handles the restoration of the backup
  echo "Starting ODO"
  docker run -t --rm --name odo \
    -e AWS_ACCESS_KEY_ID="$aws_access_key" \
    -e AWS_SECRET_ACCESS_KEY="$aws_secret_key" \
    -e AWS_DEFAULT_REGION="$aws_region" \
    -e S3_BACKUP_URL="$s3_url" \
    -e S3_ENDPOINT="$s3_endpoint" \
    -v "$new_compose_vol_name":/data odo:0.2

  if [[ $? -ne 0 ]] ; then
    echo "Failed to do oil"
    exit 5
  fi

fi

echo "Add sleep"
sleep 10
# Up container
docker compose -f $compose_filepath up -d $service

echo "#friday mood: slip 10 again"
sleep 10
# Promote master
echo "Promoting database"
docker compose -f $compose_filepath exec -u postgres $service bash -c "pg_ctl promote"



# Check if replace_conf == true
if $replace_conf; then
  # Alter config
  docker compose -f $compose_filepath cp ./confs/postgresql.auto.conf $service:/var/lib/postgresql/data/postgresql.auto.conf
  # restart container
  docker compose -f $compose_filepath restart -d $service
fi
