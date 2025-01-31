# Prerequisite
- S3 with a your backup stored on it.
	- Soon able to get backups from other sources.
- a `.env` file with the following elements:
  - `AWS_ACCESS_KEY`
  - `AWS_SECRET_KEY`
  - `AWS_REGION`
- The backup must be performed by pg_basebackup
- Backup must be gunziped

# Usage
```bash
./import_db_backup.sh -u S3_BACKUP_URL -e S3_ENDPOINT -v VOLUME_NAME -n SERVICE_NAME -f COMPOSE_FILEPATH -c REPLACE_CONF -o OVERRIDE_VOLUME -V NEW_VOLUME_NAME
```
### Args
- -u: S3 backup URL
- -e: S3 endpoint 
- -v: volume name
- -n: name the service to down (e.g. db)
- -f: path to the docker compose file
- -c: relace configuration
- -o: override volume
- -V: new volume name

#### optionnal
- -c: replace postgresql.auto.conf (uses the one defined in `confs` folder)
- -o: override the volume (DO NOT USE IN PROD, USE -V INSTEAD)
- -V: name of the new volume used for restoration
- -a: AWS access key  => should be defined in `.env`
- -s: AWS secret key  => should be defined in `.env`
- -r: AWS regioni     => should be defined in `.env`

#### -u: S3 backup URL
S3 URL pointing to the backup.

#### -e: S3 endpoint
S3 endpoint, required when using AWS CLI to request for other sources than AWS (like OVH)

#### -v: volume name
Name of the volume currently containing the database.

#### -n: name of the db service
Used to stop the service in order to perform the restoration.

#### -f: compose file path
Path to the compose file that manage the DB you want to restore.

**IMPORTANT** the file path must at least contain the parent folder name. It can be required later on.

#### -c: replace configuration
Will look in the `confs/` folder for a `postgres.auto.conf` file and if it exists it will replace the current auto conf with this file.
This allows you to override postgres configuration after the restoration.

> If you use -c without having a `postgres.auto.conf` in the `confs/` you will get a **code 3 error**

#### -o: override volume
Instruct the script to perform the restoration on the current volume.
The data in the volume will be **deleted** and replaced by the data from the backup.

#### -V: new volume name
Give the script a name for a new volume that will replace the current one.
This option will lead to the compose file also being updated with the new volume name.

The old volume will be preserved in case of error, you will need to clean it up manualy when no longer needed.
The old compose file will also be preserved by adding a .bak suffix to the original version.


### Error codes
#### code 3
Fires when using the arg `-c` that is used to override postgresql configuration. 
You get this error when there is no file named `postgresql.auto.conf` in the folder `confs`.

#### code 4
Fires when you have started ODO with unsafe volume parameters.
By default ODO will create a new volume an expect a new volume name passed with the arg `-V` (capital "v")
The other way is to use `-o` to switch to override mode and the acutal volume will be cleaned and used for the restoration

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
