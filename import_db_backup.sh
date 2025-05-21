#!/bin/bash

set -euo pipefail

# variables default values
override_volume=false
replace_conf=""
pgversion="latest"
mode=0
standby=false
odo_image="odo:latest"

# Print usage/help
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -u S3_BACKUP_URL      S3 backup URL
  -e S3_ENDPOINT        S3 endpoint
  -v VOLUME_NAME        Docker volume name
  -n SERVICE_NAME       Docker Compose service name
  -f COMPOSE_FILEPATH   Path to docker-compose file
  -c REPLACE_CONF       Path to postgresql.auto.conf to replace
  -o                    Override volume mode
  -V NEW_VOLUME_NAME    New volume name (for new volume mode)
  -p PG_VERSION         Postgres version (default: latest)
  -S                    Standby mode
  -O ODO_IMAGE          ODO docker image (default: odo:latest)
  -P BACKUP_PATH        Local backup path
  -a AWS_ACCESS_KEY     AWS access key
  -s AWS_SECRET_KEY     AWS secret key
  -r AWS_REGION         AWS region
  -h, --help            Show this help message and exit
EOF
}

# Function check AWS
check_aws() {
  if [ -z "${AWS_ACCESS_KEY:-}" ] || [ -z "${AWS_SECRET_KEY:-}" ] || [ -z "${AWS_REGION:-}" ] || [ -z "${s3_url:-}" ] || [ -z "${s3_endpoint:-}" ]; then
    echo "Error: Missing info in .env. Ensure you have set AWS_ACCESS_KEY, AWS_SECRET_KEY and AWS_REGION."
    exit 1
  fi
}
# Function arguments
check_args() {
  if [ -z "${volume_name:-}" ] || [ -z "${service:-}" ] || [ -z "${compose_filepath:-}" ]; then
    echo "Error: Missing required arguments"
    usage
    exit 1
  fi
}
# Check local backup
check_local() {
  if [ ! -e "${backup_path:-}/base.tar.gz" ] || [ ! -e "${backup_path:-}/pg_wal.tar.gz" ]; then
    echo "Error: Missing files, your local folder should contain base.tar.gz and pg_wal.tar.gz"
    exit 1 
  fi
}
# check if AWS or local backup + run differents checks
check_backup() {
  if [ -n "${backup_path:-}" ]; then
    if [ -n "${s3_url:-}" ] || [ -n "${s3_endpoint:-}" ]; then
      echo "Usage error, you can't use -P (local backup) and -u, -e (S3 option) together. You need to choose between local backup mode and S3 backup mode." 
      exit 1
    fi
    check_local
    check_args
  else
    check_aws
    check_args
  fi
}
# Function to up docker compose service and promote database to master
up_db() {
  local sleep_time="${1:-5}"
  # Up container
  docker compose -f "$compose_filepath" up -d "$service"
  sleep "$sleep_time"
  # Promote master
  echo "Promoting database"
  docker compose -f "$compose_filepath" exec -u postgres "$service" bash -c "pg_ctl promote"
}

# Function odo with S3 storage
run_odo() {
  local vol="${1:-ODO_STANDBY_VOLUME}"
  echo "Starting odo in S3 mode"
  docker run -t --rm \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
  -e AWS_DEFAULT_REGION="$AWS_REGION" \
  -e S3_BACKUP_URL="$s3_url" \
  -e S3_ENDPOINT="$s3_endpoint" \
  -v "$vol":/data "$odo_image"
}
# Function odo with local storage
run_local() {
  local vol="${1:-ODO_STANDBY_VOLUME}"
  echo "Starting odo in local backup mode"
  docker run -t --rm \
  -e backup_path="${backup_path:-}" \
  -v "${backup_path:-}":/backup \
  -v "$vol":/data "$odo_image"
}

# Function replace conf
replace_configuration() {
  if [ -n "$replace_conf" ]; then
    docker compose -f "$compose_filepath" cp "$replace_conf" "$service":/var/lib/postgresql/data/postgresql.auto.conf
    docker compose -f "$compose_filepath" restart "$service"
  fi
}

# Function recreate compose volume name
get_full_volume_name() {
  local folder_name
  folder_name=$(echo "$compose_filepath" | sed -E 's#.*/(\w+)/[^/]*\\.ya?ml$#\1#')
  local new_compose_vol_name="${folder_name}_$1"
  echo "$new_compose_vol_name"
}

# Load env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a) AWS_ACCESS_KEY="$2"; shift 2;;
    -s) AWS_SECRET_KEY="$2"; shift 2;;
    -r) AWS_REGION="$2"; shift 2;;
    -u) s3_url="$2"; shift 2;;
    -e) s3_endpoint="$2"; shift 2;;
    -v) volume_name="$2"; shift 2;;
    -n) service="$2"; shift 2;;
    -f) compose_filepath="$2"; shift 2;;
    -c) replace_conf="$2"; shift 2;;
    -o) override_volume=true; shift;;
    -V) new_volume_name="$2"; shift 2;;
    -p) pgversion="$2"; shift 2;;
    -S) standby=true; shift;;
    -O) odo_image="$2"; shift 2;;
    -P) backup_path="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "Unknown option: $1"; usage; exit 1;;
    *) break;;
  esac
done

if $standby; then
  mode=1
  check_backup
fi
echo $override_volume
if $override_volume; then
  if (( $mode != 0 )); then
    echo "Usage error, you can't use -o and -S at the same time"
    exit 1
  fi
  # Check parameter for override_volume mode
  mode=2
  check_backup
fi


if [[ -n "${new_volume_name:-}" ]]; then
  if (( mode != 0 )); then
    echo "Usage error, you can't use -V and -o or -S at the same time"
    exit 1
  fi
  mode=3
  check_backup
  if [ "${volume_name:-}" == "${new_volume_name:-}" ]; then
    echo "You need to specify a new volume name different from actual volume name"
    exit 1
  fi
fi

# Check if replace_conf is true and postgresql.auto.conf is provided
if [ -n "$replace_conf" ]; then
    echo "l.187 - REPLACE CONF"
    if [ ! -e "$replace_conf" ]; then
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
    if [ -n "${backup_path:-}" ]; then
      run_local
    else
      run_odo
    fi
    docker run -d --rm \
    -v ODO_STANDBY_VOLUME:/var/lib/postgresql/data \
    postgres:"$pgversion"
    ;;
  2)
    # Run recovery in override mode
    # Down container
    docker compose -f "$compose_filepath" down "$service"

    vol_name=$(get_full_volume_name "$volume_name")
    # Odo handles the restoration of the backup
    # run in local or aws mode
    echo "starting ODO"
    if [ -n "${backup_path:-}" ]; then
      run_local "$vol_name"
    else
      run_odo "$vol_name"
    fi
    up_db
    replace_configuration
    ;;
  3)
    # Run recovery on new volume mode
    # Down container
    docker compose -f "$compose_filepath" down "$service"
    echo "Creating new volume: $new_volume_name"
    echo "Updating compose file"
    sed -i.bak "s/$volume_name/$new_volume_name/g" "$compose_filepath"
    docker compose -f "$compose_filepath" up -d "$service"
    docker compose -f "$compose_filepath" down "$service"
    new_compose_vol_name=$(get_full_volume_name "$new_volume_name")
    # Odo handles the restoration of the backup
    # run in local or aws mode
    echo "Starting ODO"
    if [ -n "${backup_path:-}" ]; then
      run_local "$new_compose_vol_name"
    else
      run_odo "$new_compose_vol_name"
    fi
    up_db
    replace_configuration
    ;;
esac
