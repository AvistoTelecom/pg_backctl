#!/bin/bash

# variables default values
replace_conf=false
override_volume=false
replace_conf=false
pgversion="latest"
mode=0
standby=false
odo_image="odo:latest"

# Function check AWS
check_aws() {
  if [ -z "$AWS_ACCESS_KEY" ] || [ -z "$AWS_SECRET_KEY" ] || [ -z "$AWS_REGION" ]; then
    echo "Error: Missing info in .env. Ensure you have set AWS_ACCESS_KEY, AWS_SECRET_KEY and AWS_REGION."
    exit 1
  fi
}
# Function arguments
check_args() {
  if [ -z "$s3_url" ] || [ -z "$s3_endpoint" ] || [ -z "$volume_name" ] || [ -z "$service" ] || [ -z "$compose_filepath" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -u S3_BACKUP_URL -e S3_ENDPOINT -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH"
    exit 1
  fi
}
# Check local backup
check_local() {
  if [ ! -e "$backup_path/base.tar.gz"] || [ ! -e "$backup_path/pg_wal.tar.gz" ]; then
    echo "Error: Missing files, your local folder should contain base.tar.gz and pg_wal.tar.gz"
    exit 1 
  fi
}
# check if AWS or local backup + run differents checks
check_backup() {
  if [ -z "$backup_path" ]; then
    if [ -z "$AWS_ACCESS_KEY" ] || [ -z "$AWS_SECRET_KEY" ] || [ -z "$AWS_REGION" ]; then
      echo "Usage error, you can't use -P and a + s + r + u + e in the same time. You need to choose between local backup mode and AWS backup mode." 
      exit 1
    fi
    check_local
  else
    check_aws
    check_args
}
# Function to up docker compose service and promote database to master
up_db() {
  # Up container
  docker compose -f $compose_filepath up -d $service
  sleep ${1:-5}
  # Promote master
  echo "Promoting database"
  docker compose -f $compose_filepath exec -u postgres $service bash -c "pg_ctl promote"
}

# Function odo with S3 storage
run_odo() {
  echo "Starting odo in S3 mode"
  docker run -t --rm \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY \
  -e AWS_DEFAULT_REGION=$AWS_REGION \
  -e S3_BACKUP_URL=$s3_url \
  -e S3_ENDPOINT=$s3_endpoint \
  -v ${1:-"ODO_STANDBY_VOLUME"}:/data $odo_image
}
# Function odo with local storage
run_local() {
  echo "Starting odo in local backup mode"
  docker run -t --rm \
  -e backup_path=$backup_path \
  -v $backup_path:/backup \
  -v ${1:-"ODO_STANDBY_VOLUME"}:/data $odo_image
}

# Function replace conf
replace_configuration() {
  # Check if replace_conf == true
  if $replace_conf; then
    # Alter config
    docker compose -f $compose_filepath cp ./confs/postgresql.auto.conf $service:/var/lib/postgresql/data/postgresql.auto.conf
    # restart container
    docker compose -f $compose_filepath restart -d $service
  fi
}

# Function recreate compose volume name
get_full_volume_name() {
  # Get compose folder prefix and add it to new_volume_name
  folder_name=$(echo "$compose_filepath" | sed -E 's/.*\/(\w+)\/[^\/]*\.ya?ml$/\1/')
  new_compose_vol_name=${folder_name}_${1}
  echo "$new_compose_vol_name"
}

# Load env
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Parse command line arguments
while getopts "asru:e:v:n:f:coV:p:SO:P:" opt; do
  case $opt in
    a) AWS_ACCESS_KEY="$OPTARG";;
    s) AWS_SECRET_KEY="$OPTARG";;
    r) AWS_REGION="$OPTARG";;
    u) s3_url="$OPTARG";;
    e) s3_endpoint="$OPTARG";;
    v) volume_name="$OPTARG";;
    n) service="$OPTARG";;
    f) compose_filepath="$OPTARG";;
    c) replace_conf=true;;
    o) override_volume=true;;
    V) new_volume_name="$OPTARG";;
    p) pgversion="$OPTARG";;
    S) standby=true;;
    O) odo_image="$OPTARG";;
    P) backup_path="$OPTARG";;
    ?) echo "Usage: $0 -u S3_BACKUP_URL -e S3_ENDPOINT -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH -c REPLACE_CONF -o OVERRIDE_VOLUME -V NEW_VOLUME_NAME" >&2
       exit 1;;
  esac
done

if $standby; then
  mode=1
  check_backup
fi

if $override_volume; then
  if (( $mode != 0 )); then
    echo "Usage error, you can't use -o and -S at the same time"
    exit 1
  fi
  # Check parameter for override_volume mode
  mode=2
  check_backup
fi


if [[ -n "$new_volume_name" ]]; then
  if (( $mode != 0 )); then
    echo "Usage error, you can't use -V and -o or -S at the same time"
    exit 1
  fi
  mode=3
  check_backup
  if [ $volume_name == $new_volume_name ]; then
    echo "You need to specify a new volume name different from actual volume name"
    exit 1
  fi
fi

# Check if replace_conf is true and postgresql.auto.conf is provided
if $replace_conf; then
    echo "REPLACE CONF"
    if [ ! -e ./confs/postgresql.auto.conf ]; then
      echo "option -c to replace config is set to true but postgresql.auto.conf is missing"
      exit 1
  fi
fi

case $mode in
  0)
    # check if a recovery mode is selected
    echo "Please specify the recovery mode by using either -o, -V or -S"
    exit 1
    ;;
  1)
    # Run in standby mode
    # run in local or aws mode
    echo "Starting ODO"
    if [ -z "$backup_path" ]; then
      run_local
    else
      run_odo
    fi
    docker run -d --rm \
    -v ODO_STANDBY_VOLUME:/var/lib/postgresql/data \
    postgres:$pgversion
    ;;
  2)
    # Run recovery in override mode
    # Down container
    docker compose -f $compose_filepath down $service
    
    vol_name=$(get_full_volume_name $volume_name)
    # Odo handles the restoration of the backup
    # run in local or aws mode
    echo "starting ODO"
    if [ -z "$backup_path" ]; then
      run_local $vol_name
    else
      run_odo $vol_name
    fi
    up_db 
    replace_configuration
    ;;
  3)
    # Run recovery on new volume mode
    # Down container
    docker compose -f $compose_filepath down $service
    echo "Creating new volume: $new_volume_name"
    echo "Updating compose file"
    sed -i.bak "s/$volume_name/$new_volume_name/g" $compose_filepath
    docker compose -f $compose_filepath up -d $service
    docker compose -f $compose_filepath down $service
    new_compose_vol_name=$(get_full_volume_name $new_volume_name)
    # Odo handles the restoration of the backup
    # run in local or aws mode
    echo "Starting ODO"
    if [ -z "$backup_path" ]; then
      run_local $new_compose_vol_name
    else
      run_odo $new_compose_vol_name
    fi
    up_db
    replace_configuration
    ;;
esac
 

