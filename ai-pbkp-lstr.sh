#!/bin/bash
#
# Parallel rsync backup system
# Implements three-phase execution:
#   1. Expand - Walk directory tree to build task queue
#   2. Pool   - Drive tasks through fixed-size worker pool
#   3. Analyse - Scan task logs for rsync errors
#

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

# Source|destination pairs (semicolon-separated)
# Default: local backup and remote backup to localhost
# Remote format: server:path (rsync will use SSH for remote destinations)
BACKUP_JOBS="${BACKUP_JOBS:-./test_data|./test_backup/test_data;./test_data|localhost:/nfs/ihfs/home_metis/serguei/aibkpcl/test_remote_backup/test_data}"

# rsync flags
RSYNC_OPTS="-lptgoDzhHAx --delete -v"

# Directory patterns to exclude (weekdays vs Saturday)
WEEKDAY_FILTER="climlab_scratch"
SATURDAY_FILTER="314159027"

# Log directory
LOG_DIR="./bkplog"

# Default concurrency (80% of available cores)
CORES=$(nproc 2>/dev/null || echo 4)
DEFAULT_JOBS=$((CORES * 8 / 10))
if [[ $DEFAULT_JOBS -lt 1 ]]; then
    DEFAULT_JOBS=1
fi

# Lock file to prevent concurrent runs (use script name without extension)
SCRIPT_NAME=$(basename "$0" .sh)
LOCK_FILE="/tmp/.running_backup_${SCRIPT_NAME}"

# Global log file (defined after SCRIPT_NAME is set)
GLOBAL_LOG="${LOG_DIR}/${SCRIPT_NAME}_$(date '+%Y%m%d_%H%M%S').blg"

# ==============================================================================
# Utility Functions
# ==============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$GLOBAL_LOG"
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }

# Check if today is Saturday
is_saturday() {
    [[ $(date +%u) -eq 6 ]]
}

# Get appropriate filter based on day of week
get_filter() {
    if is_saturday; then
        echo "$SATURDAY_FILTER"
    else
        echo "$WEEKDAY_FILTER"
    fi
}

# Calculate the depth of a directory tree (max depth)
calculate_depth() {
    local src_dir="$1"
    local max_depth=0

    # Find directories at depth 1 under src_dir (direct children)
    while IFS= read -r dir; do
        local rel_path="${dir#$src_dir}"
        # Remove leading slash for accurate depth calculation
        rel_path="${rel_path#/}"
        local depth
        depth=$(echo "$rel_path" | tr -cd '/' | wc -c)
        if [[ $depth -gt $max_depth ]]; then
            max_depth=$depth
        fi
    done < <(fd --type directory --min-depth 1 --max-depth 1 . "$src_dir" 2>/dev/null)

    # Return at least 1, or 0 if no directories found
    if [[ $max_depth -eq 0 ]]; then
        echo 1
    else
        echo "$max_depth"
    fi
}

# ==============================================================================
# Lock Management
# ==============================================================================

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Backup already running (PID: $pid)"
            exit 1
        fi
        # Stale lock file, remove it
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap release_lock EXIT
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ==============================================================================
# Phase 1: Expand - Build Task Queue
# ==============================================================================

build_task_queue() {
    local src_dir="$1"
    local dest_dir="$2"
    local depth="$3"
    local task_queue="$4"

    # Find directories at depth 1 under src_dir (direct children)
    fd --type directory --min-depth 1 --max-depth 1 "." "$src_dir" | while read -r dir; do
        # Output task with depth relative to src_dir
        local rel_depth
        rel_depth=$(echo "$dir" | sed "s|^$src_dir||" | tr -cd '/' | wc -c)
        echo "$rel_depth|$dir|$dest_dir${dir#$src_dir}"
    done | sort -t'|' -k1 -n > "$task_queue"
}

# ==============================================================================
# Phase 2: Pool - Worker Pool Management
# ==============================================================================

process_worker() {
    local worker_id="$1"
    local task_queue="$2"
    local log_dir="$3"
    local dry_run="$4"

    while true; do
        # Atomically fetch next task using flock
        local task_file="${task_queue}.task"
        local task
        (
            flock -x 200
            task=$(head -n1 "$task_queue" 2>/dev/null)
            if [[ -z "$task" ]]; then
                rm -f "$task_file"
                exit 0
            fi
            tail -n +2 "$task_queue" > "${task_queue}.tmp"
            mv "${task_queue}.tmp" "$task_queue"
            echo "$task" > "$task_file"
        ) 200>"${task_queue}.lock"

        if [[ ! -f "$task_file" ]]; then
            break
        fi
        task=$(cat "$task_file")
        rm -f "$task_file"

        local level src dest
        IFS='|' read -r level src dest <<< "$task"

        local log_file="$log_dir/worker_${worker_id}_level_${level}.log"

        # Parse destination to detect remote format (server:path)
        # Remote format: remoteserver:path-to-remote-backup-folder
        if [[ "$dest" =~ ^[^:]+:.+ ]]; then
            # Remote destination - create remote directory using ssh
            remote_host="${dest%%:*}"
            remote_path="${dest#*:}"
            # Check if remote host is reachable
            if ! ping -c 1 -W 5 "$remote_host" >/dev/null 2>&1 && ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$remote_host" exit >/dev/null 2>&1; then
                log_error "Remote host '$remote_host' is not reachable"
                exit 1
            fi
            ssh "$remote_host" "mkdir -p '$remote_path'"
        else
            # Local destination - create directory
            mkdir -p "$dest"
        fi

        # Run rsync
        local rsync_cmd="rsync $RSYNC_OPTS"

        if [[ "$level" -lt "$depth" ]]; then
            # Non-recursive for shallower directories
            rsync_cmd="$rsync_cmd --dirs"
        else
            # Recursive for depth (covers full subtree)
            rsync_cmd="$rsync_cmd -r"
        fi

        # Apply filter
        local filter
        filter=$(get_filter)
        rsync_cmd="$rsync_cmd --exclude=$filter"

        # Dry run flag
        if [[ "$dry_run" == "true" ]]; then
            rsync_cmd="$rsync_cmd --dry-run"
        fi

        rsync_cmd="$rsync_cmd $src/ $dest/"

        log_info "Worker $worker_id: $rsync_cmd"
        echo "Running: $rsync_cmd" >> "$log_file"
        eval "$rsync_cmd" >> "$log_file" 2>&1 || true
    done
}

run_worker_pool() {
    local task_queue="$1"
    local jobs="$2"
    local log_dir="$3"
    local dry_run="$4"

    # Create worker processes with staggered start to reduce race conditions
    local pids=()
    for ((i = 1; i <= jobs; i++)); do
        process_worker "$i" "$task_queue" "$log_dir" "$dry_run" &
        pids+=($!)
        sleep 0.05  # Small delay between starting each worker
    done

    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
}

# ==============================================================================
# Phase 3: Analyse - Scan Logs for Errors
# ==============================================================================

analyse_logs() {
    local log_dir="$1"
    local error_count=0

    log_info "Scanning logs for errors..."

    # Error patterns (case-insensitive) - specific rsync error messages
    local error_patterns=(
        "rsync error:"
        "rsync error:"
        "error:"  # error: with colon indicates actual error
    )

    for log_file in "$log_dir"/worker_*.log; do
        [[ -f "$log_file" ]] || continue

        for pattern in "${error_patterns[@]}"; do
            if grep -qi "$pattern" "$log_file" 2>/dev/null; then
                log_error "Error found in $log_file: $pattern"
                ((error_count++))
            fi
        done
    done

    if [[ $error_count -gt 0 ]]; then
        log_error "Found $error_count error(s) in backup logs"
        return 1
    fi

    log_info "No errors found in backup logs"
    return 0
}

# ==============================================================================
# Help and Usage
# ==============================================================================

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--jobs N] [--depth N]

Options:
    --dry-run   Show what would be done without making changes
    --jobs N    Number of parallel workers (default: $DEFAULT_JOBS)
    --depth N   Maximum directory depth to process (default: calculated from source)
    --help      Show this help message

Configuration (environment variables):
    BACKUP_JOBS   Source:destination pairs (semicolon-separated)
    RSYNC_OPTS    rsync flags (default: $RSYNC_OPTS)
    LOG_DIR       Per-task logs directory (default: $LOG_DIR)
EOF
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    local dry_run="false"
    local jobs="$DEFAULT_JOBS"
    local depth=""
    local depth_specified="false"
    local cmd_args="$*"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run="true"
                shift
                ;;
            --jobs)
                jobs="$2"
                shift 2
                ;;
            --depth)
                depth="$2"
                depth_specified="true"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done


    # Acquire lock
    acquire_lock

    # Create log directory and clear old logs
    mkdir -p "$LOG_DIR"
    rm -f "$LOG_DIR"/worker_*.log
    rm -f "$LOG_DIR"/*.blg
    touch "$GLOBAL_LOG"

    # Log job start time and configuration
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Job started at $(date)" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] BACKUP_JOBS=$BACKUP_JOBS" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Command: $0 $cmd_args" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] --------------------------" >> "$GLOBAL_LOG"

    # Check that source directories have README files
    IFS=';' read -ra jobs_array <<< "$BACKUP_JOBS"
    for job in "${jobs_array[@]}"; do
        IFS='|' read -r src dest <<< "$job"
        if [[ -d "$src" ]] && [[ ! -f "$src/README" ]]; then
            log_error "Source directory '$src' must contain a README file"
            exit 1
        fi
    done

    # If depth not specified, calculate from source directory structure
    if [[ "$depth_specified" != "true" ]]; then
        IFS=';' read -ra jobs_array <<< "$BACKUP_JOBS"
        for job in "${jobs_array[@]}"; do
            IFS='|' read -r src dest <<< "$job"
            if [[ -d "$src" ]]; then
                local calculated_depth
                calculated_depth=$(calculate_depth "$src")
                log_info "Calculated depth for $src: $calculated_depth"
                if [[ -z "$depth" ]] || [[ $calculated_depth -gt $depth ]]; then
                    depth=$calculated_depth
                fi
            fi
        done
        # Fallback to default if still not set
        if [[ -z "$depth" ]]; then
            depth=1
        fi
    fi

    log_info "Starting backup with $jobs workers, depth=$depth"
    if [[ "$dry_run" == "true" ]]; then
        log_info "DRY RUN MODE - No changes will be made"
    fi

    # Process each backup job
    IFS=';' read -ra jobs_array <<< "$BACKUP_JOBS"
    for job in "${jobs_array[@]}"; do
        IFS='|' read -r src dest <<< "$job"

        if [[ ! -d "$src" ]]; then
            log_error "Source directory does not exist: $src"
            continue
        fi

        log_info "Processing: $src -> $dest"

        # Build task queue
        local task_queue
        task_queue=$(mktemp)
        build_task_queue "$src" "$dest" "$depth" "$task_queue"

        local task_count
        task_count=$(wc -l < "$task_queue")
        log_info "Built task queue with $task_count tasks"

        # Run worker pool
        run_worker_pool "$task_queue" "$jobs" "$LOG_DIR" "$dry_run"

        # Cleanup temp task queue
        rm -f "$task_queue"
    done

    # Analyse logs for errors
    analyse_logs "$LOG_DIR"

    # Log job end time
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] --------------------------" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Job ended at $(date)" >> "$GLOBAL_LOG"
}

main "$@"
