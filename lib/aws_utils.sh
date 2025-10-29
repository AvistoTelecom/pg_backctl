#!/bin/bash

# AWS utilities for pg_backctl
# Provides AWS credential validation and configuration helpers

# Check if AWS credentials are configured
# Usage: check_aws_credentials
# Returns: 0 if valid, 1 if missing
check_aws_credentials() {
  if [ -z "${AWS_ACCESS_KEY:-}" ] || [ -z "${AWS_SECRET_KEY:-}" ] || [ -z "${AWS_REGION:-}" ]; then
    return 1
  fi
  return 0
}

# Check if S3 configuration is valid
# Usage: check_s3_config
# Returns: 0 if valid, 1 if missing
check_s3_config() {
  if [ -z "${s3_url:-}" ] || [ -z "${s3_endpoint:-}" ]; then
    return 1
  fi
  return 0
}

# Validate all AWS and S3 requirements
# Usage: validate_aws_and_s3
# Dies with error if validation fails
validate_aws_and_s3() {
  if ! check_aws_credentials; then
    die "Missing AWS credentials. Ensure you have set AWS_ACCESS_KEY, AWS_SECRET_KEY and AWS_REGION in .env or via arguments." $ERR_MISSING_ENV
  fi

  if ! check_s3_config; then
    die "Missing S3 configuration. Both s3_url and s3_endpoint are required for S3 operations." $ERR_MISSING_ARG
  fi
}

# Configure AWS CLI with credentials
# Usage: configure_aws_cli
# Sets up AWS CLI configuration in the current environment
configure_aws_cli() {
  if ! check_aws_credentials; then
    die "Cannot configure AWS CLI: credentials not set" $ERR_MISSING_ENV
  fi

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY"
  aws configure set aws_secret_access_key "$AWS_SECRET_KEY"
  aws configure set default.region "$AWS_REGION"
}

# Get S3 bucket name from s3_url
# Usage: bucket_name=$(get_s3_bucket)
get_s3_bucket() {
  local bucket="${s3_url#s3://}"
  bucket="${bucket%/}"
  echo "$bucket"
}
