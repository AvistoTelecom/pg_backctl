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
pg_backctl_image="pg_backctl:latest"
replace_pg_hba_conf=""
post_init_conf=""
config_file=""
s3_backup_path=""  # Full S3 path to backup (e.g., "backups/20250124T143000" or "postgresql-cluster/base/backup-name")
s3_search_prefix="postgresql-cluster/base/"  # Default search prefix for auto-detect (backward compatible)

# Function to parse INI-style config file
parse_config_file() {
  local config_path="$1"

  if [ ! -f "$config_path" ]; then
    die "Config file not found: $config_path" $ERR_USAGE
  fi

  echo "Loading configuration from: $config_path"

  local current_section=""

  while IFS= read -r line || [ -n "$line" ]; do
    # Remove leading/trailing whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Check for section header
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      continue
    fi

    # Parse key=value pairs
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      # Trim whitespace from key and value
      key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Remove quotes if present
      value=$(echo "$value" | sed 's/^["'\'']\(.*\)["'\'']$/\1/')

      # Map config file keys to script variables
      case "$current_section" in
        source)
          case "$key" in
            s3_url) s3_url="$value" ;;
            s3_endpoint) s3_endpoint="$value" ;;
            s3_backup_path) s3_backup_path="$value" ;;
            s3_search_prefix) s3_search_prefix="$value" ;;
            path) backup_path="$value" ;;
          esac
          ;;
        target)
          case "$key" in
            volume_name) volume_name="$value" ;;
            service) service="$value" ;;
            compose_file) compose_filepath="$value" ;;
          esac
          ;;
        restore)
          case "$key" in
            standby) [[ "$value" =~ ^(true|yes|1)$ ]] && standby=true ;;
            override_volume) [[ "$value" =~ ^(true|yes|1)$ ]] && override_volume=true ;;
            new_volume_name) new_volume_name="$value" ;;
          esac
          ;;
        postgres)
          case "$key" in
            version) pgversion="$value" ;;
            replace_conf) replace_conf="$value" ;;
            replace_pg_hba_conf) replace_pg_hba_conf="$value" ;;
            post_init_conf) post_init_conf="$value" ;;
          esac
          ;;
        aws)
          case "$key" in
            access_key) AWS_ACCESS_KEY="$value" ;;
            secret_key) AWS_SECRET_KEY="$value" ;;
            region) AWS_REGION="$value" ;;
          esac
          ;;
        docker)
          case "$key" in
            image) pg_backctl_image="$value" ;;
          esac
          ;;
      esac
    fi
  done < "$config_path"
}

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
  Configuration:
  -c, --config FILE     Load configuration from file (overrides defaults)

  Backup source:
  -u S3_BACKUP_URL      S3 backup URL
  -e S3_ENDPOINT        S3 endpoint
  -P BACKUP_PATH        Local backup path

  Target database:
  -v VOLUME_NAME        Docker volume name (required unless in config)
  -n SERVICE_NAME       Docker Compose service name (required unless in config)
  -f COMPOSE_FILEPATH   Path to docker-compose file (required unless in config)

  Restore mode (choose ONE):
  -S                    Standby mode (create standby/replica)
  -o                    Override volume mode (WARNING: deletes existing data!)
  -V NEW_VOLUME_NAME    New volume mode (create new volume with restored data)

  PostgreSQL configuration:
  -p PG_VERSION         Postgres version (default: latest)
  -C REPLACE_CONF       Path to postgresql.auto.conf to replace
  -H REPLACE_PG_HBA     Path to pg_hba.conf to replace
  -I POST_INIT_CONF     Path to folder with custom scripts to run after restore

  Docker:
  -O PG_BACKCTL_IMAGE   pg_backctl docker image (default: pg_backctl:latest)

  AWS credentials (optional, can be set in .env or config file):
  -a AWS_ACCESS_KEY     AWS access key
  -s AWS_SECRET_KEY     AWS secret key
  -r AWS_REGION         AWS region

  -h, --help            Show this help message and exit

Examples:
  # Using a config file
  $0 -c recovery.conf

  # Config file with CLI override for standby mode
  $0 -c recovery.conf -S

  # Restore from S3 backup, override current volume (no config file)
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -o

  # Restore from S3 backup, create new volume
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -V new-db-volume-name

  # Restore from local backup
  $0 -P /path/to/backup -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -o

  # Replace Postgres config after restore
  $0 -u s3://bucket -e https://s3.endpoint -v db-volume-name -n db-service-name -f /path/to/docker-compose.yml -C confs/postgresql.auto.conf -o

Config File:
  See recovery.conf.example for a complete configuration file example.
  Config file uses INI format with sections: [source], [target], [restore], [postgres], [aws], [docker]
  Command-line arguments override config file values.
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

# Function pg_backctl with S3 storage
run_pg_backctl() {
  local vol="${1:-PG_BACKCTL_STANDBY_VOLUME}"
  echo "> Starting restoration in S3 mode"

  # Build docker run command with optional S3_BACKUP_PATH
  local docker_cmd="docker run -t --rm \
  -e AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY\" \
  -e AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_KEY\" \
  -e AWS_DEFAULT_REGION=\"$AWS_REGION\" \
  -e S3_BACKUP_URL=\"$s3_url\" \
  -e S3_ENDPOINT=\"$s3_endpoint\""

  # Add S3_BACKUP_PATH if specified (specific backup mode)
  if [ -n "$s3_backup_path" ]; then
    echo "> Using specific S3 backup path: $s3_backup_path"
    docker_cmd="$docker_cmd -e S3_BACKUP_PATH=\"$s3_backup_path\""
  else
    # Auto-detect mode - pass search prefix
    echo "> Auto-detecting latest backup in: $s3_search_prefix"
    docker_cmd="$docker_cmd -e S3_SEARCH_PREFIX=\"$s3_search_prefix\""
  fi

  docker_cmd="$docker_cmd -v \"$vol\":/data \"$pg_backctl_image\""

  eval "$docker_cmd"
}
# Function pg_backctl with local storage
run_local() {
  local vol="${1:-PG_BACKCTL_STANDBY_VOLUME}"
  echo "Starting pg_backctl in local backup mode"
  docker run -t --rm \
  -e backup_path="${backup_path:-}" \
  -v "${backup_path:-}":/backup \
  -v "$vol":/data "$pg_backctl_image"
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
    echo "> Replacing postgresql.auto.conf with custom configuration..."
    docker compose -f "$compose_filepath" cp "$replace_conf" "$service":/var/lib/postgresql/data/postgresql.auto.conf
    docker compose -f "$compose_filepath" restart "$service"
    echo "  ✓ Configuration replaced and service restarted"
  else
    echo "> Skipping postgresql.auto.conf replacement (not configured)"
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
    echo "> Replacing pg_hba.conf with custom configuration..."
    docker compose -f "$compose_filepath" cp "$replace_pg_hba_conf" "$service":/var/lib/postgresql/data/pg_hba.conf
    docker compose -f "$compose_filepath" restart "$service"
    echo "  ✓ pg_hba.conf replaced and service restarted"
  else
    echo "> Skipping pg_hba.conf replacement (not configured)"
  fi
}

# Function recreate compose volume name
get_full_volume_name() {
  local folder_name
  folder_name=$(basename "$(dirname "$compose_filepath")")
  local new_compose_vol_name="${folder_name}_$1"
  echo "$new_compose_vol_name"
}

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"

# Parse command line arguments (first pass - check for config file)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      config_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      # Store remaining args for second pass
      break
      ;;
  esac
done

# Load .env file first (lowest priority)
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Load config file if specified (medium priority - overrides .env)
if [ -n "$config_file" ]; then
  parse_config_file "$config_file"
  echo "Configuration loaded from: $config_file"
fi

# Parse remaining command line arguments (highest priority - overrides config file)
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
    -C) replace_conf="$2"; shift 2;;
    -o) override_volume=true; shift;;
    -V) new_volume_name="$2"; shift 2;;
    -p) pgversion="$2"; shift 2;;
    -S) standby=true; shift;;
    -O) pg_backctl_image="$2"; shift 2;;
    -P) backup_path="$2"; shift 2;;
    -H) replace_pg_hba_conf="$2"; shift 2;;
    -I) post_init_conf="$2"; shift 2;;
    -c|--config) shift 2;;  # Already handled in first pass
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
    echo "Starting pg_backctl"
    if [ -n "${backup_path:-}" ]; then
      run_local
    else
      run_pg_backctl
    fi
    docker run -d --rm \
    -v PG_BACKCTL_STANDBY_VOLUME:/var/lib/postgresql/data \
    postgres:"$pgversion"

    echo ""
    echo "========================================="
    echo "✓ Standby database started successfully!"
    echo "========================================="
    echo "Volume: PG_BACKCTL_STANDBY_VOLUME"
    echo "PostgreSQL version: $pgversion"
    echo ""
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

    # pg_backctl handles the restoration of the backup
    # run in local or aws mode
    echo "> Starting pg_backctl on $vol_name"
    if [ -n "${backup_path:-}" ]; then
      run_local "$vol_name"
    else
      run_pg_backctl "$vol_name"
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

    echo ""
    echo "========================================="
    echo "✓ Recovery completed successfully!"
    echo "========================================="
    echo "Database restored to volume: $vol_name"
    echo "Service: $service (running)"
    echo ""
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
    # pg_backctl handles the restoration of the backup
    # run in local or aws mode
    echo "Starting pg_backctl"
    if [ -n "${backup_path:-}" ]; then
      run_local "$new_compose_vol_name"
    else
      run_pg_backctl "$new_compose_vol_name"
    fi
    up_db
    replace_configuration
    replace_pg_hba
    echo ""
    echo "========================================="
    echo "✓ Recovery completed successfully!"
    echo "========================================="
    echo "Database restored to volume: $new_volume_name"
    echo "Service: $service"
    echo "Compose file: $compose_filepath"
    echo ""
    ;;
  *)
  die "Unknown error or mode" $ERR_UNKNOWN
  ;;
esac

# Final success message for all modes
echo ""
echo "✓ Database recovery completed successfully"
echo ""
