# Meet ODO, Optimized Data Operations

ODO comes with a custom docker image and a script to run a full restoration of a database from an S3 bucket.

To work, it needs to be run mounted with the volume of the database.

## Usage

```bash
./import_db_backup.sh -a AWS_ACCESS_KEY -s AWS_SECRET_KEY -r AWS_REGION -u S3_BACKUP_URL
```

## Docker Image Overview

When run, the docker image expects 4 environement variables:
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- AWS_DEFAULT_REGION
- S3_BACKUP_URL

During execution, the docker image will:

1. **Grab Latest Backup**: It fetches the latest backup from the S3 bucket.
2. **Clean the volume**: It removes all the content of the /data folder.
3. **Restore basebackup**: It restores the basebackup that contains a checkpoint of the database.
4. **Restore WAL**: It restores the WAL to get the database to the last consistent state.
5. **Create recovery.signal**: This file is used to tell that the database has to perform a recovery.
6. **Change owner**: It changes the owner of the /data folder to 999:999 which is the postgres user and group.

## TODO
- [ ] Default behavior => Grab latest backup
- [ ] Override possibility to specify a backup