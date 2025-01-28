# Prerequisite
- S3 with a your backup stored on it.
	- Soon able to get backups from other sources.
- The backup must be performed by pg_basebackup
- Backup must be gunziped

# Usage
```bash
./import_db_backup.sh -a AWS_ACCESS_KEY -s AWS_SECRET_KEY -r AWS_REGION -u S3_BACKUP_URL -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH
```
### Args
- -a: AWS access key
- -s: AWS secret key
- -r: AWS region
- -u: S3 backup URL
- -v: volume name
- -n: name the service to down (e.g. db)
- -f: path to the docker compose file

### Error codes
#### code 3
Fires when using the arg `-c` that is used to override postgresql configuration. 
You get this error when there is no file named `postgresql.auto.conf` in the folder `confs`.

## Docker image overview
When run, the docker image expects 4 environment variables:
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

# What is ODO?

**ODO** (Optimized Data Operation) is a tool designed to streamline the restoration of backups made with **pg_basebackup**. It aims to simplify the more complex aspects of physical backups restoration process without diving into tricky manual steps.

## Why ODO?
In the attempt of matching Postgres recommended way of doing backups, we chose to provide a tool that improves backup restoration procedures. PostgreSQL offers two primary methods for backups:
- **pg_dump** (logical backups)
- **pg_basebackup** (physical backups)
They both serve the same purpose but differ significantly in approach, performance, and restoration complexity.
### Comparison Matrix

| **Criteria**           | **pg_dump**                                           | **pg_basebackup**                                               |
| ---------------------- | ----------------------------------------------------- | --------------------------------------------------------------- |
| **Backup Type**        | Logical                                               | Physical                                                        |
| **Output**             | SQL scripts or custom binary format                   | Entire PostgreSQL data directory (provides compression options) |
| **Scope**              | Selected tables / databases                           | Full database cluster (including config)                        |
| **Restoration**        | Flexible (can restore to different versions)          | Requires same version & structure (physical copy)               |
| **Use Cases**          | Upgrades, partial backups, portability, dev scripting | Clean full backups, fast full restores, PITR                    |
| **Performance Impact** | Higher CPU (during dump)                              | Primarily I/O-bound                                             |
| **Ease of Setup**      | Simple, few prerequisites                             | Needs more prep (replication config, etc.)                      |

### TL;DR
Overall, **pg_basebackup** has advantages over **pg_dump**:
- uses **replication privilege** which does not need a password (with our `pg_hba` config)
- enables **PITR**
- **fast** full restores
- strong data **integrity**. 

However, there are some trade-offs:
- Additional **configuration** requirements
- More **complex** restoration steps

## How It Works (ODO)

ODO is started on the db volume in order to perform the following steps:

- **Fetch Latest Backup**: ODO locates and retrieves the most recent CNPG backup from a given S3 bucket.
    
- **Clean the Volume**: The contents of the `data` folder are wiped.
    
- **Restore Basebackup**: The tool lays down the physical backup checkpoint into `data`.
    
- **Restore WAL**: Like basebackup, it loads the Write-Ahead Logs (WAL).
    
- **Create `recovery.signal`**: This file signals to PostgreSQL that it must enter recovery mode upon startup.
    
- **Adjust Ownership**: Sets the owner and group of the `data` folder to `999:999` (the Postgres user).
    
- **Restart the Database**: Once the necessary files and permissions are in place, the database service is restarted.
    
- **Promote the Database**: Finally, the node is promoted, making it into the new primary (master) database if required.

---

## What's Next?

1. [x] **Update Postgres conf if needed** ⭐
2. [ ] **Mount the S3 volume instead of downloading it** 🚀
3. [ ] **Support for specific backup selection instead of latest** 🔖
4. [ ] Add an arg to create a new volume. 
	1. [ ] Have a secondary mod to mount a temporary DB
5. [ ] Fetch backups from other sources than a S3
6. [ ] Improve Documentation
	1. [ ] Use cases
	2. [ ] Recommendation of usage (screen / tmux)
> PROD READY
7. [ ] Add preliminary checks & robustness
	1. [ ] Check disk space 
	2. [ ] Check format of input data
	3. [ ] Add checkpoints to avoid full restart in case of failure
8. [ ] Support for incremental backups


### For much later

- Support for PITR 
- Rework of backups (May not be handled by ODO)
	- Especialy for non-kube projects
