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
ADMIN_EMAIL="admin@example.com"
DATE="$(date +%Y%m%d)"
HOSTNAME="$(hostname -s)"
# Source|destination pairs (array of "source;destination" strings)
# Default: local backup and remote backup to localhost
# Remote format: server:path (rsync will use SSH for remote destinations)
# Example: export BACKUP_JOBS=("./src|/dest" "server:/path|/local/dest")
# To override: export BACKUP_JOBS=("./src|/dest" "server:/path|/local/dest")
if [[ ${#BACKUP_JOBS[@]} -eq 0 ]] 2>/dev/null; then
    BACKUP_JOBS=("./test_data|./test_backup/test_data" "./test_data|localhost:/nfs/ihfs/home_metis/serguei/aibkpcl/test_remote_backup/test_data")
fi

# rsync flags
RSYNC_OPTS="-lptgoDzhHAx --delete -v --numeric-ids"

# Directory patterns to exclude (weekdays vs Saturday)
WEEKDAY_FILTER="climlab_scratch"
SATURDAY_FILTER="314159027"

# Log directory
LOG_DIR="./bkplog"

# Function to get core count from a host (local or remote)
get_host_cores() {
    local host="$1"
    if [[ "$host" == "localhost" ]] || [[ "$host" == "127.0.0.1" ]] || [[ "$host" == "$(hostname)" ]]; then
        nproc 2>/dev/null || echo 4
    else
        # SSH to remote host and get core count, filtering out ANSI codes using head -1
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "nproc" 2>/dev/null | head -1 || echo 4
    fi
}

# Check if destination supports rsync -X option (extended attributes)
# Returns "yes" if supported, "no" otherwise
check_rsync_xattr_support() {
    local dest_dir="$1"
    local test_dir="${dest_dir}/.rsync_xattr_test_$$"
    local result="no"

    # Create test directory
    if mkdir -p "$test_dir" 2>/dev/null; then
        # Try to set an extended attribute
        if setfattr -n user.test -v "test" "$test_dir" 2>/dev/null; then
            # If setfattr succeeds, try rsync with -X
            if rsync --help 2>&1 | grep -q "\-X, --xattrs"; then
                # Test rsync with -X on this filesystem
                if rsync -X --dry-run "$test_dir"/ "$test_dir"/backup 2>/dev/null; then
                    result="yes"
                fi
            fi
        fi
        # Cleanup
        rm -rf "$test_dir" 2>/dev/null || true
    fi

    echo "$result"
}

# Calculate minimum cores across all hosts in BACKUP_JOBS
calculate_min_cores() {
    local min_cores
    local cores
    min_cores=$(nproc 2>/dev/null || echo 4)

    # Parse BACKUP_JOBS to extract remote hosts
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r src dest <<< "$job"
        # Extract host from destination (format: server:path or just path for local)
        if [[ "$dest" =~ ^([^:]+): ]]; then
            local host="${BASH_REMATCH[1]}"
            cores=$(get_host_cores "$host")
            if [[ $cores -lt $min_cores ]]; then
                min_cores=$cores
            fi
        fi
    done
    echo "$min_cores"
}

# Default concurrency (80% of minimum cores across all hosts)
MIN_CORES=$(calculate_min_cores)
MAX_JOBS=$((MIN_CORES * 4 / 5))
if [[ $MAX_JOBS -lt 1 ]]; then
    MAX_JOBS=1
fi

# Lock file to prevent concurrent runs (use script name without extension)
SCRIPT_NAME=$(basename "$0" .sh)
LOCK_FILE="/tmp/.running_backup_${SCRIPT_NAME}"

# Global log file (defined after SCRIPT_NAME is set)
GLOBAL_LOG="${LOG_DIR}/${SCRIPT_NAME}_$(date '+%Y%m%d_%H%M%S').blg"

# Check for fd (fast directory finder) dependency
check_fd_dependencies() {
    if ! command -v fd &> /dev/null; then
        log_error "Command 'fd' not found. Please install the fd-find package:"
        log_error "  sudo apt-get install fd-find  # Debian/Ubuntu"
        log_error "  sudo yum install fd-find      # RHEL/CentOS"
        log_error "  brew install fd               # macOS"
        exit 1
    fi

    # Verify fd version (requires fd 8.0+ for --min-depth)
    local fd_version
    fd_version=$(fd --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$fd_version" ]]; then
        local major
        major=$(echo "$fd_version" | cut -d. -f1)
        if [[ $major -lt 8 ]]; then
            log_error "fd version $fd_version found, but version 8.0+ is required"
            log_error "Please update fd-find package"
            exit 1
        fi
    fi
}

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

    # Find all directories under src_dir (excluding src_dir itself)
    while IFS= read -r dir; do
        local rel_path="${dir#$src_dir}"
        # Remove leading slash for accurate depth calculation
        rel_path="${rel_path#/}"
        local depth
        depth=$(echo "$rel_path" | tr -cd '/' | wc -c)
        if [[ $depth -gt $max_depth ]]; then
            max_depth=$depth
        fi
    done < <(fd --type directory --min-depth 1 . "$src_dir" 2>/dev/null)

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
            #Admin have to check the problem or no futher backups will be done
            log  "Backup at $HOSTNAME @ $DATE: Lock file $LOCKFILE is present; assume the previous backup is still running; exit" 
            #                                                                      
            echo "FYI" | mailx -s "Backup at $HOSTNAME @ $DATE: Lock file $LOCKFILE is present; assume the previous backup is still running; exit"  ${ADMIN_EMAIL}

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
    local rsync_opts="$5"

    # Create a task directory with unique task files
    local task_dir="${task_queue}.tasks"
    rm -rf "$task_dir"
    mkdir -p "$task_dir"

    # Add source directory itself as a task (for files directly in source)
    # This ensures files in the root source folder are backed up
    local task_file="${task_dir}/task_$(printf '%06d' 0)"
    echo "0|$src_dir|$dest_dir|$rsync_opts" > "$task_file"
    local task_id=1

    # Find all directories under src_dir up to the specified depth
    # Directories at depth < specified: use --dirs (non-recursive)
    # Directories at depth == specified: use -r (recursive to cover full subtree)
    while IFS= read -r dir; do
        # Calculate depth relative to src_dir
        local rel_path="${dir#$src_dir}"
        rel_path="${rel_path#/}"
        local rel_depth
        rel_depth=$(echo "$rel_path" | tr -cd '/' | wc -c)

        # Only include directories up to and including the specified depth
        if [[ $rel_depth -le $depth ]]; then
            local entry="$dir|$rel_depth|$dest_dir${dir#$src_dir}"
            IFS='|' read -r d rel_depth dest_path <<< "$entry"
            task_file="${task_dir}/task_$(printf '%06d' $task_id)"
            echo "$rel_depth|$d|$dest_path|$rsync_opts" > "$task_file"
            ((task_id++)) || true
        fi
    done < <(fd --type directory --min-depth 1 . "$src_dir")
}

# ==============================================================================
# Phase 2: Pool - Worker Pool Management
# ==============================================================================

process_task() {
    local task_file="$1"
    local log_dir="$2"
    local dry_run="$3"
    local max_depth="$4"

    local task
    task=$(cat "$task_file")
    rm -f "$task_file"

    local level src dest rsync_opts
    IFS='|' read -r level src dest rsync_opts <<< "$task"

    # Use worker_id based on task file number for consistent logging
    local worker_id="${task_file##*/}"
    worker_id="${worker_id#task_}"
    local log_file="$log_dir/task_${worker_id}.log"

    # Parse destination to detect remote format (server:path)
    # Remote format: remoteserver:path-to-remote-backup-folder
    if [[ "$dest" =~ ^[^:]+:.+ ]]; then
        # Remote destination - create remote directory using ssh
        local remote_host="${dest%%:*}"
        local remote_path="${dest#*:}"
        # Check if remote host is reachable
        if ! ping -c 1 -W 5 "$remote_host" >/dev/null 2>&1 && ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$remote_host" exit >/dev/null 2>&1; then
            log_error "Remote host '$remote_host' is not reachable"
            return 1
        fi
        ssh "$remote_host" "mkdir -p '$remote_path'" 2>&1 | tee -a "$log_file"
    else
        # Local destination - create directory
        mkdir -p "$dest"
    fi

    # Run rsync
    local rsync_cmd="rsync $rsync_opts"

    # Handle the root task (level 0) specially - always recursive to include all files
    # For subdirectories: --dirs for shallower, -r for max depth
    if [[ "$level" -eq 0 ]]; then
        # Root task - always recursive to backup all files and subdirectories
        rsync_cmd="$rsync_cmd -r"
    elif [[ "$level" -lt "$max_depth" ]]; then
        # Non-recursive for shallower directories (just the directory itself)
        rsync_cmd="$rsync_cmd --dirs"
    else
        # Recursive for max depth (covers full subtree)
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

    log_info "Task $worker_id: $rsync_cmd"
    echo "Running: $rsync_cmd" >> "$log_file"
    eval "$rsync_cmd" >> "$log_file" 2>&1
    return $?
}

run_worker_pool() {
    local task_queue="$1"
    local task_dir="${task_queue}.tasks"
    local jobs="$2"
    local log_dir="$3"
    local dry_run="$4"
    local max_depth="$5"
    local rsync_opts="$6"

    # Store running PIDs in an array
    local running_pids=()
    local task_count=0

    while true; do
        # Get next available task
        local task_file
        task_file=$(find "$task_dir" -name "task_*" -type f 2>/dev/null | head -1)

        if [[ -z "$task_file" ]]; then
            # No more tasks to process
            break
        fi

        # Try to claim the task by renaming it to .processing
        local task_processing="${task_file}.processing"
        if mv "$task_file" "$task_processing" 2>/dev/null; then
            task_file="$task_processing"
        else
            # Task was already claimed by another process, wait briefly
            sleep 0.05
            continue
        fi

        # Start task in background
        process_task "$task_file" "$log_dir" "$dry_run" "$max_depth" &
        local pid=$!
        running_pids+=($pid)
        ((task_count++)) || true

        # If we've hit the job limit, wait for at least one to complete
        if [[ ${#running_pids[@]} -ge $jobs ]]; then
            # Wait for any one job to complete
            local found_completed=false
            local new_pids=()

            for pid in "${running_pids[@]}"; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    wait "$pid" 2>/dev/null || true
                    found_completed=true
                    # Skip this pid (it's done)
                else
                    new_pids+=("$pid")
                fi
            done
            running_pids=("${new_pids[@]}")

            # If no job completed (all still running), wait a bit
            if [[ "$found_completed" == "false" ]]; then
                sleep 0.1
            fi
        fi
    done

    # Wait for all remaining jobs to complete
    for pid in "${running_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Clean up task directory
    rm -rf "$task_dir"
}

# ==============================================================================
# Phase 3: Analyse - Scan Logs for Errors
# ==============================================================================

analyse_logs() {
    local log_dir="$1"
    local error_count=0
    local error_summary=""

    log_info "Scanning logs for errors..."

    # Error patterns (case-insensitive) - specific rsync error messages
    local error_patterns=(
        "rsync error:"
        "error:"  # error: with colon indicates actual error
    )

    for log_file in "$log_dir"/worker_*.log; do
        [[ -f "$log_file" ]] || continue

        while IFS= read -r line; do
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $line" >> "$GLOBAL_LOG"
        done < <(grep -i "error:" "$log_file" 2>/dev/null || true)
    done

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
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Error Summary: $error_count error(s) found in backup logs" >> "$GLOBAL_LOG"
        return 1
    fi

    log_info "No errors found in backup logs"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Error Summary: No errors found" >> "$GLOBAL_LOG"
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
    --jobs N    Number of parallel workers (default: $MAX_JOBS)
    --depth N   Maximum directory depth to process (default: calculated from source)
    --help      Show this help message

Configuration (environment variables):
    BACKUP_JOBS   Array of "source;destination" pairs
    RSYNC_OPTS    rsync flags (default: $RSYNC_OPTS)
    LOG_DIR       Per-task logs directory (default: $LOG_DIR)
EOF
}

# Build rsync options based on destination capabilities
build_rsync_options() {
    local dest="$1"
    local opts="$RSYNC_OPTS"

    # Check if destination supports -X (extended attributes)
    local xattr_support
    xattr_support=$(check_rsync_xattr_support "$dest")
    if [[ "$xattr_support" == "yes" ]]; then
        opts="$opts -X"
    fi

    echo "$opts"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    # Check dependencies
    check_fd_dependencies

    local dry_run="false"
    local jobs="$MAX_JOBS"
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
                local specified_jobs="$2"
                # Use MAX_JOBS if --jobs is greater than MAX_JOBS
                if [[ $specified_jobs -gt $MAX_JOBS ]]; then
                    jobs="$MAX_JOBS"
                else
                    jobs="$specified_jobs"
                fi
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] BACKUP_JOBS=(${BACKUP_JOBS[*]})" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] MAX_JOBS=$MAX_JOBS" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Command: $0 $cmd_args" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] --------------------------" >> "$GLOBAL_LOG"

    # Check that source directories have README files
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r src dest <<< "$job"
        if [[ -d "$src" ]] && [[ ! -f "$src/README" ]]; then
            log_error "Source directory '$src' must contain a README file"
            exit 1
        fi
    done

    # If depth not specified, calculate from source directory structure
    if [[ "$depth_specified" != "true" ]]; then
        for job in "${BACKUP_JOBS[@]}"; do
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
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r src dest <<< "$job"

        if [[ ! -d "$src" ]]; then
            log_error "Source directory does not exist: $src"
            continue
        fi

        log_info "Processing: $src -> $dest"

        # Build rsync options for this destination
        local rsync_opts
        rsync_opts=$(build_rsync_options "$dest")
        log_info "Using rsync options: $rsync_opts"

        # Build task queue
        local task_queue
        task_queue=$(mktemp)
        build_task_queue "$src" "$dest" "$depth" "$task_queue" "$rsync_opts"

        local task_count
        task_count=$(find "${task_queue}.tasks" -name "task_*" -type f 2>/dev/null | wc -l)
        log_info "Built task queue with $task_count tasks"

        # Run worker pool
        run_worker_pool "$task_queue" "$jobs" "$LOG_DIR" "$dry_run" "$depth" "$rsync_opts"
    done

    # Analyse logs for errors
    analyse_logs "$LOG_DIR"

    # Log job end time
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] --------------------------" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Job ended at $(date)" >> "$GLOBAL_LOG"
}

main "$@"
