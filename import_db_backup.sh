#!/bin/bash

set -euo pipefail

# Error codes
ERR_MISSING_CONF=3      # -c used but postgresql.auto.conf missing
ERR_UNSAFE_VOLUME=4     # Unsafe volume operation
ERR_MISSING_CMD=10      # Required command not found
ERR_MISSING_ENV=11      # Missing required environment variable
ERR_MISSING_ARG=12      # Missing required argument
ERR_LOCAL_BACKUP=13     # Local backup files missing
ERR_USAGE=14            # Usage error (bad arg combination)
ERR_UNKNOWN=99          # Unknown error

# Print error and exit with code 
die() {
  local msg="$1"
  local code="${2:-$ERR_UNKNOWN}"
  echo "Error $code: $msg" >&2
  exit "$code"
}

# variables default values
override_volume=false
replace_conf=""
replace_init_conf=""
pgversion="latest"
mode=0
standby=false
odo_image="odo:latest"
replace_pg_hba_conf=""
post_init_conf=""

# Check for required external commands
for cmd in docker sed grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command '$cmd' not found in PATH. Please install it before running this script." $ERR_MISSING_CMD
  fi
done

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
  -H REPLACE_PG_HBA     Path to pg_hba.conf to replace
  -I POST_INIT_CONF     Path to a folder with custom scripts to run after restore
  -h, --help            Show this help message and exit

Examples:
  # Restore from S3 backup, override current volume
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -o

  # Restore from S3 backup, create new volume
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -V new-db-volume-name

  # Restore from local backup
  $0 -P /path/to/backup -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -o

  # Replace Postgres config after restore
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -c confs/postgresql.auto.conf -o
EOF
}

# Function check AWS
check_aws() {
  if [ -z "${AWS_ACCESS_KEY:-}" ] || [ -z "${AWS_SECRET_KEY:-}" ] || [ -z "${AWS_REGION:-}" ] || [ -z "${s3_url:-}" ] || [ -z "${s3_endpoint:-}" ]; then
    die "Missing info in .env. Ensure you have set AWS_ACCESS_KEY, AWS_SECRET_KEY and AWS_REGION." $ERR_MISSING_ENV
  fi
}
# Function arguments
check_args() {
  if [ -z "${volume_name:-}" ] || [ -z "${service:-}" ] || [ -z "${compose_filepath:-}" ]; then
    die "Missing required arguments" $ERR_MISSING_ARG
  fi
}
# Check local backup
check_local() {
  if [ ! -e "${backup_path:-}/base.tar.gz" ] || [ ! -e "${backup_path:-}/pg_wal.tar.gz" ]; then
    die "Missing files, your local folder should contain base.tar.gz and pg_wal.tar.gz" $ERR_LOCAL_BACKUP
  fi
}
# check if AWS or local backup + run differents checks
check_backup() {
  if [ -n "${backup_path:-}" ]; then
    if [ -n "${s3_url:-}" ] || [ -n "${s3_endpoint:-}" ]; then
      die "You can't use -P (local backup) and -u, -e (S3 option) together. Choose between local backup mode and S3 backup mode." $ERR_USAGE
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
  local sleep_time="10"
  # Up container
  docker compose -f "$compose_filepath" up -d "$service"

  if [ -n "$replace_init_conf" ]; then
    replace_init_configuration
  fi
  
  echo "Sleeping for $sleep_time seconds to allow the database to start..."
  sleep "$sleep_time"
}

# Function odo with S3 storage
run_odo() {
  local vol="${1:-ODO_STANDBY_VOLUME}"
  echo "> Starting restoration in S3 mode"
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

replace_init_configuration() {
  if [ -n "$replace_init_conf" ]; then
    docker compose -f "$compose_filepath" cp "$replace_init_conf" "$service":/var/lib/postgresql/data/postgresql.auto.conf
    docker compose -f "$compose_filepath" restart "$service"
  fi
}

# Function replace conf
replace_configuration() {
  if [ -n "$replace_conf" ]; then
    docker compose -f "$compose_filepath" cp "$replace_conf" "$service":/var/lib/postgresql/data/postgresql.auto.conf
    docker compose -f "$compose_filepath" restart "$service"
  fi
}

# Function to copy and execute post-init SQL scripts in the container
post_init_script() {
  if [ -n "$post_init_conf" ]; then
    echo "Copying and running post-init SQL scripts from $post_init_conf..."

    # Copy the folder into the container
    docker compose -f "$compose_filepath" cp "$post_init_conf" "$service":/tmp/init-scripts/

    # Get DB/user/password from env or set defaults
    local db="${POST_INIT_SCRIPT_DATABASE:-postgres}"
    local user="${POST_INIT_SCRIPT_USER:-postgres}"
    local pass="${POST_INIT_SCRIPT_PASSWORD:-}"

    # Export password for psql if provided
    local pass_env=""
    if [ -n "$pass" ]; then
      pass_env="PGPASSWORD=$pass"
    fi

    echo "Waiting for the database to be ready..."
    sleep 5  # Wait for the container to be ready

    # Execute each .sql script in alphabetical order
    for script in $(find "$post_init_conf" -maxdepth 1 -type f -name "*.sql" | sort); do
      filename=$(basename "$script")
      echo "Executing script: $filename"
      # Use docker compose exec to run psql inside the container
      if [ -n "$pass" ]; then
        docker compose -f "$compose_filepath" exec -T "$service" bash -c "PGPASSWORD='$pass' psql -U '$user' -d '$db' -f '/tmp/init-scripts/$filename'"
      else
        docker compose -f "$compose_filepath" exec -T "$service" psql -U "$user" -d "$db" -f "/tmp/init-scripts/$filename"
      fi
    done
  else
    echo "> Skiped: No post-init scripts provided in $post_init_conf"
  fi
}

# Function to copy pg_hba.conf into the container
replace_pg_hba() {
  if [ -n "$replace_pg_hba_conf" ]; then
    docker compose -f "$compose_filepath" cp "$replace_pg_hba_conf" "$service":/var/lib/postgresql/data/pg_hba.conf
    docker compose -f "$compose_filepath" restart "$service"
  fi
}

# Function recreate compose volume name
get_full_volume_name() {
  local folder_name
  folder_name=$(basename "$(dirname "$compose_filepath")")
  local new_compose_vol_name="${folder_name}_$1"
  echo "$new_compose_vol_name"
}

# Robust env loading
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
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
    -H) replace_pg_hba_conf="$2"; shift 2;;
    -I) post_init_conf="$2"; shift 2;;
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

if $override_volume; then
  if (( $mode != 0 )); then
    die "You can't use -o and -S at the same time" $ERR_USAGE
  fi
  # Check parameter for override_volume mode
  mode=2
  check_backup
fi


if [[ -n "${new_volume_name:-}" ]]; then
  if (( mode != 0 )); then
    die "You can't use -V and -o or -S at the same time" $ERR_USAGE
  fi
  mode=3
  check_backup
  if [ "${volume_name:-}" == "${new_volume_name:-}" ]; then
    die "You need to specify a new volume name different from actual volume name" $ERR_USAGE
  fi
fi

# Check if replace_conf is true and postgresql.auto.conf is provided
if [ -n "$replace_conf" ]; then
    if [ ! -e "$replace_conf" ]; then
      die "option -c to replace config is set to true but postgresql.auto.conf is missing" $ERR_MISSING_CONF
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

    # Check if service is running ? => if not warn

    # Down container
    docker compose -f "$compose_filepath" down "$service"

    echo "get docker compose volume name of $volume_name"
    vol_name=$(get_full_volume_name "$volume_name")

    # Check if volume exists
    if ! docker volume ls | grep -q "$vol_name"; then
      die "Volume $vol_name does not exist" $ERR_UNSAFE_VOLUME
    fi

    # Odo handles the restoration of the backup
    # run in local or aws mode
    echo "> Starting ODO on $vol_name"
    if [ -n "${backup_path:-}" ]; then
      run_local "$vol_name"
    else
      run_odo "$vol_name"
    fi
    echo "> Basebackup restored to $vol_name"

    # Build replace_init_conf from replace_conf if replace_conf is set
    if [ -n "$replace_conf" ]; then
      replace_init_conf="${replace_conf%.auto.conf}.init.auto.conf"
      if [ -e "$replace_init_conf" ]; then
      
      echo "> Replacing postgresql.auto.conf with $replace_init_conf"
      up_db

      echo "> Replacing pg_hba.conf with $replace_pg_hba_conf"
      replace_pg_hba # Moved this step first to ensure pg_hba.conf is updated before running post init scripts to avoid any access issues

      echo "> Running post init scripts"
      post_init_script
      
      replace_configuration
      
      else
        die "option -c to replace config is set to true but postgresql.auto.conf is missing" $ERR_MISSING_CONF
      fi
    else
      # Up container
      up_db
      replace_pg_hba
    fi
    
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
    replace_pg_hba
    ;;
  *)
  die "Unknown error or mode" $ERR_UNKNOWN
  ;;
esac
