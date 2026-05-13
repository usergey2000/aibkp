#!/bin/bash
# Backup /home/serguei to /ssdr5/cache/tmp/serguei

export BACKUP_JOBS=("/home/serguei|/ssdr5/cache/tmp/serguei")

# Source the main script which will call main "$@"
source /nfs/ihfs/home_metis/serguei/aibkpcl/ai-backup.sh
