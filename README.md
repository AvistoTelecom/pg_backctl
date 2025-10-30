# pg_backctl

> PostgreSQL backup and restore made easy with pg_basebackup

[![License: PostgreSQL](https://img.shields.io/badge/License-PostgreSQL-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](https://www.docker.com/)
[![PostgreSQL](https://img.shields.io/badge/postgresql-16%2B-blue.svg)](https://www.postgresql.org/)

## Overview

**pg_backctl** (PostgreSQL Backup Control) is a command-line tool that simplifies creating and restoring PostgreSQL physical backups using `pg_basebackup`. It handles the complexity of backup operations, S3 storage, WAL management, and configuration so you can focus on your data.

### Key Features

- 🚀 **Easy Backups** - Create physical backups with `pg_basebackup` (gzip/bzip2 compression)
- 📦 **S3 Integration** - Upload/download backups to/from S3-compatible storage
- 🔄 **WAL Management** - Automatic WAL fetching and replay for point-in-time recovery
- 🔐 **Integrity Checks** - SHA256 checksums for backup verification
- ⏰ **Retention Policies** - Auto-cleanup old backups (by count or age)
- 🐳 **Docker Native** - Works seamlessly with Docker Compose
- ⚙️ **Config Files** - INI-style configuration for easy automation
- 🎯 **Multiple Modes** - Override, new volume, or standby/replica modes

## Quick Start

### Create a Backup

```bash
# 1. Copy the example config
cp backup.conf.example backup.conf

# 2. Edit backup.conf with your settings
# 3. Run backup
./create_backup.sh -c backup.conf
```

### Restore a Backup

```bash
# 1. Copy the example config
cp recovery.conf.example recovery.conf

# 2. Edit recovery.conf with your settings
# 3. Run restore
./import_db_backup.sh -c recovery.conf
```

That's it! 🎉

## Installation

### Prerequisites

- **Docker** and **Docker Compose** installed
- S3-compatible storage (AWS S3, OVH, MinIO, etc.) or local storage
- PostgreSQL database running in Docker Compose
- `.env` file with AWS credentials (for S3 mode):
  ```bash
  AWS_ACCESS_KEY=your_access_key
  AWS_SECRET_KEY=your_secret_key
  AWS_REGION=us-east-1
  ```

### Building the Docker Image

```bash
docker build -t pg_backctl:latest .
```

## Configuration

### Backup Configuration

Create `backup.conf` from the example:

```ini
[database]
service = postgres
compose_file = docker-compose.yml
user = replication_user

[destination]
s3_url = s3://mybucket
s3_endpoint = https://s3.provider.com
s3_prefix = backups

[backup]
compression = gzip
retention_count = 10
```

See [backup.conf.example](backup.conf.example) for all options.

### Recovery Configuration

Create `recovery.conf` from the example:

```ini
[source]
s3_url = s3://mybucket
s3_endpoint = https://s3.provider.com
s3_search_prefix = backups/

[target]
volume_name = pgdata
service = postgres
compose_file = docker-compose.yml

[restore]
new_volume_name = pgdata-restored
```

See [recovery.conf.example](recovery.conf.example) for all options.

## Usage Examples

### Backup Scenarios

#### Daily Automated Backups

```bash
# Add to crontab
0 2 * * * /path/to/pg_backctl/create_backup.sh -c /path/to/backup.conf
```

#### Manual Backup with Custom Label

```bash
./create_backup.sh -c backup.conf -l "pre-migration-$(date +%Y%m%d)"
```

#### Local Backup (No S3)

```bash
./create_backup.sh \
  -n postgres \
  -f docker-compose.yml \
  -P /backups/postgres
```

#### Backup with bzip2 Compression

Edit `backup.conf`:
```ini
[backup]
compression = bzip2  # Better compression, slower
```

### Recovery Scenarios

#### Restore Latest Backup to New Volume (Recommended)

```bash
# Safest option - creates new volume, keeps original
./import_db_backup.sh -c recovery.conf
```

#### Restore Specific Backup (Point-in-Time Recovery)

Edit `recovery.conf`:
```ini
[source]
s3_backup_path = backups/20251027T143000  # Specific backup
```

Then restore:
```bash
./import_db_backup.sh -c recovery.conf
```

#### Restore and Override Existing Volume

⚠️ **WARNING:** This deletes existing data!

```bash
./import_db_backup.sh -c recovery.conf -o
```

#### Create Standby/Replica Server

```bash
./import_db_backup.sh -c recovery.conf -S
```

#### Restore from Local Backup

```bash
./import_db_backup.sh \
  -P /backups/20251027T143000 \
  -v pgdata \
  -n postgres \
  -f docker-compose.yml \
  -V pgdata-restored
```

#### Restore with Custom Configuration

```bash
./import_db_backup.sh \
  -c recovery.conf \
  -C confs/postgresql.auto.conf \
  -H confs/pg_hba.conf
```

## Advanced Features

### Backup Checksums

pg_backctl automatically generates SHA256 checksums for all backup files, enabling external verification tools to validate backup integrity.

Each backup includes:
- `backup.sha256` - SHA256 checksums for all files
- `backup.sha256.info` - Metadata describing the checksum format

**Manual Verification:**
```bash
# Download backup
aws s3 cp s3://bucket/backups/20251027T143000/ ./backup --recursive

# Verify integrity
cd backup
sha256sum -c backup.sha256
```

**Why external verification?**
- Separates concerns (backup creation vs. verification)
- Allows scheduled verification independent of backup timing
- Integrates with your existing monitoring stack
- Can verify old backups for bit rot detection

### Retention Policies

Automatically cleanup old backups from S3 to save storage costs.

**Keep last N backups:**
```ini
[backup]
retention_count = 10  # Keep last 10 backups
```

**Keep backups for N days:**
```ini
[backup]
retention_days = 30  # Keep backups for 30 days
```

**Note:** `retention_count` takes precedence if both are set.

### S3 Path Flexibility

pg_backctl supports multiple S3 path structures:

```ini
# Organized by prefix (recommended)
s3_prefix = backups

# Backward compatible with other tools
s3_prefix = postgresql-cluster/base

# Root level storage
s3_prefix =
```

**Auto-detect vs. Specific Backup:**

```ini
# Auto-detect: restore latest backup
s3_search_prefix = backups/

# Specific: restore exact backup
s3_backup_path = backups/20251027T143000
```

### Restore Modes

#### 1. New Volume Mode (Recommended)
Creates a new volume, leaving the original intact.

```bash
./import_db_backup.sh -c recovery.conf -V pgdata-restored
```

#### 2. Override Mode
⚠️ Replaces existing volume data (destructive).

```bash
./import_db_backup.sh -c recovery.conf -o
```

#### 3. Standby Mode
Creates a standby/replica server.

```bash
./import_db_backup.sh -c recovery.conf -S
```

## CLI Reference

### create_backup.sh

```bash
./create_backup.sh [OPTIONS]

Options:
  -c, --config FILE     Load configuration from file
  -n SERVICE_NAME       Docker Compose service name
  -f COMPOSE_FILEPATH   Path to docker-compose file
  -u S3_BACKUP_URL      S3 backup URL (e.g., s3://mybucket)
  -e S3_ENDPOINT        S3 endpoint URL
  -P BACKUP_PATH        Local backup path (alternative to S3)
  -l BACKUP_LABEL       Custom backup label
  -C COMPRESSION        Compression: gzip, bzip2, none (default: gzip)
  -U DB_USER            Database user (default: postgres)
  -O IMAGE              pg_backctl docker image (default: pg_backctl:latest)
  -h, --help            Show help message
```

**Priority:** `.env` < config file < CLI arguments

### import_db_backup.sh

```bash
./import_db_backup.sh [OPTIONS]

Options:
  -c, --config FILE     Load configuration from file
  -u S3_BACKUP_URL      S3 backup URL
  -e S3_ENDPOINT        S3 endpoint URL
  -P BACKUP_PATH        Local backup path
  -v VOLUME_NAME        Docker volume name
  -n SERVICE_NAME       Docker Compose service name
  -f COMPOSE_FILEPATH   Path to docker-compose file
  -o                    Override volume mode (WARNING: deletes data!)
  -V NEW_VOLUME_NAME    New volume mode (recommended)
  -S                    Standby mode
  -C REPLACE_CONF       Replace postgresql.auto.conf after restore
  -H REPLACE_PG_HBA     Replace pg_hba.conf after restore
  -I POST_INIT_CONF     Directory with post-init SQL scripts
  -O IMAGE              pg_backctl docker image
  -h, --help            Show help message
```

## Architecture

### How Backups Work

1. **Connect to Database** - Uses `pg_basebackup` via Docker Compose service
2. **Create Physical Backup** - Generates base backup + WAL files in tar format
3. **Compress** - Apply gzip or bzip2 compression
4. **Generate Checksums** - Create SHA256 manifest (backup.sha256)
5. **Upload to S3** - Transfer all files to S3-compatible storage
6. **Apply Retention** - Cleanup old backups based on retention policy
7. **Log Results** - JSON logs for monitoring (New Relic, etc.)

**Backup Structure:**
```
s3://bucket/backups/20251027T143000/
├── base.tar.gz          # Base backup
├── pg_wal.tar.gz        # WAL files
├── backup_manifest      # PostgreSQL manifest
├── backup.sha256        # SHA256 checksums
└── backup.sha256.info   # Checksum metadata
```

### How Recovery Works

1. **Download Backup** - Fetch backup files from S3 or use local path
2. **Clean Volume** - Wipe `/data` directory contents
3. **Restore Base Backup** - Extract base.tar.gz to `/data`
4. **Restore WAL Files** - Extract pg_wal.tar.gz to `/data/pg_wal`
5. **Create recovery.signal** - Tell PostgreSQL to perform recovery
6. **Start Database** - Launch PostgreSQL container
7. **Replace Configs** - Apply custom postgresql.auto.conf / pg_hba.conf (optional)
8. **Run Post-Init Scripts** - Execute SQL scripts (optional)

### Compatibility

**PostgreSQL Versions:** 12, 13, 14, 15, 16, 17+

**Backup Formats Supported:**
- pg_backctl format: `base.tar.gz` + `pg_wal.tar.gz`
- Legacy format: `data.tar.bz2` (backward compatible)

**S3 Providers:**
- AWS S3
- OVH Cloud Storage
- DigitalOcean Spaces
- MinIO
- Any S3-compatible storage

## Troubleshooting

### Common Issues

#### Error: "No backups found in s3://bucket/prefix"

**Cause:** S3 path mismatch or wrong prefix

**Solution:**
1. Check `s3_search_prefix` in recovery.conf
2. List bucket contents: `aws s3 ls s3://bucket/ --endpoint-url $endpoint`
3. Use `/` to search root level

#### Error: "Insufficient disk space"

**Cause:** Not enough free disk space for backup

**Solution:**
1. Check disk space: `df -h /tmp`
2. Increase `min_disk_space_gb` threshold or free up space
3. For S3 backups, ensure /tmp has enough space

#### Error: "S3 upload failed"

**Cause:** AWS credentials, network, or endpoint issue

**Solution:**
1. Verify credentials in `.env`
2. Test S3 connection: `aws s3 ls s3://bucket --endpoint-url $endpoint`
3. Check S3 endpoint URL is correct

#### Backup verification failed

**Cause:** Files missing or corrupted during upload

**Solution:**
1. Retry backup
2. Check network stability
3. Verify S3 endpoint reliability

### Error Codes

| Code | Description | Common Cause |
|------|-------------|--------------|
| 10 | Missing command | Docker or required tool not installed |
| 11 | Missing env variable | AWS credentials not set |
| 12 | Missing argument | Required CLI argument not provided |
| 14 | Usage error | Invalid argument combination |
| 15 | Backup failed | Backup or upload operation failed |
| 16 | Insufficient disk space | Not enough free space |

### FAQ

**Q: Can I backup multiple databases?**
A: Yes, `pg_basebackup` backs up the entire PostgreSQL cluster (all databases).

**Q: How long do backups take?**
A: Depends on database size. For 10GB: ~5-10 minutes with gzip.

**Q: Can I restore to a different PostgreSQL version?**
A: Only within the same major version (e.g., 15.x to 15.y is OK, 15.x to 16.x is not).

**Q: What's the difference between gzip and bzip2?**
A: gzip is faster, bzip2 has better compression. For most cases, use gzip.

**Q: How do I test my backups?**
A: Use the new volume mode (-V) to restore to a test volume periodically.

## Monitoring & Observability

pg_backctl generates logs in nginx combined log format for integration with monitoring tools like New Relic Infrastructure agent.

**Log Location:** `logs/backup.log`

**Log Format:** nginx combined log format
```
$hostname - $service [$time_local] "$event_type label HTTP/1.1" $status $bytes "$destination" "$user_agent"
```

**Example Log Entry:**
```
myhost - pg_backctl [27/Oct/2024:16:52:10 +0000] "backup_completed 20251027T143000 HTTP/1.1" 200 1073741824 "s3://mybucket/backups/20251027T143000" "pg_backctl/1.3.0 compression=gzip duration=450s"
```

**Event Types:**
- `backup_started` - Backup operation initiated
- `backup_completed` - Backup finished successfully
- `backup_failed` - Backup encountered an error
- `backup_uploaded` - Backup uploaded to S3
- `retention_cleanup` - Old backups removed

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

1. Clone the repository
2. Make your changes
3. Test thoroughly
4. Submit a PR with a clear description

### Reporting Issues

Please use GitHub Issues to report bugs or request features.

Include:
- pg_backctl version
- PostgreSQL version
- Error messages and logs
- Steps to reproduce

## License

PostgreSQL License - See [LICENSE](LICENSE) file for details
