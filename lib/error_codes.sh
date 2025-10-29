#!/bin/bash

# Centralized error code definitions for pg_backctl
# All scripts should source this file for consistent error handling

# Configuration and argument errors (10-19)
ERR_MISSING_CMD=10       # Required command not found
ERR_MISSING_ENV=11       # Missing required environment variable
ERR_MISSING_ARG=12       # Missing required argument
ERR_MISSING_CONF=13      # Missing or invalid configuration
ERR_USAGE=14             # Usage error (bad arg combination)

# Operation-specific errors (15-29)
ERR_BACKUP_FAILED=15     # Backup operation failed
ERR_DISK_SPACE=16        # Insufficient disk space
ERR_RESTORE_FAILED=17    # Restore operation failed
ERR_UNSAFE_VOLUME=18     # Unsafe volume operation

# General errors (90-99)
ERR_UNKNOWN=99           # Unknown error
