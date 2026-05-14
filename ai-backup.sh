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
# Example: BACKUP_JOBS=("./src|/dest" "server:/path|/local/dest") ./ai-backup.sh
# Or use a wrapper script that sets the array before sourcing
# Note: Array cannot be exported from shell environment, so use string fallback
BACKUP_JOBS=("${BACKUP_JOBS[@]+"${BACKUP_JOBS[@]}"}")
if [[ ${#BACKUP_JOBS[@]} -eq 0 ]] && [[ -n "${BACKUP_JOBS:-}" ]]; then
    # BACKUP_JOBS is a string (from export), parse it
    IFS=';' read -ra BACKUP_JOBS <<< "${BACKUP_JOBS:-}"
fi
if [[ ${#BACKUP_JOBS[@]} -eq 0 ]]; then
    BACKUP_JOBS=("./test_data|localhost:$PWD/test_remote_backup/test_data")
fi

# rsync flags
RSYNC_OPTS="-lptgoDzhHAx --delete -v --numeric-ids --inplace"

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
        # SSH to remote host and get core count
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "nproc" 2>/dev/null | head -1 || echo 4
    fi
}

# Check if destination supports rsync -X option (extended attributes)
# Returns "yes" if supported, "no" otherwise
check_rsync_xattr_support() {
    local dest_dir="$1"
    local test_dir="${dest_dir}/.rsync_xattr_test_$$"
    local result="no"

    # Check if rsync supports -X first
    if ! rsync --help 2>&1 | grep -q "\-X, --xattrs"; then
        echo "$result"
        return 0
    fi

    # Create test directory
    mkdir -p "$test_dir" 2>/dev/null || {
        echo "$result"
        return 0
    }

    # Try to set an extended attribute
    if setfattr -n user.test -v "test" "$test_dir" 2>/dev/null; then
        # Test rsync with -X on this filesystem
        if rsync -X --dry-run "$test_dir"/ "$test_dir"/backup >/dev/null 2>&1; then
            result="yes"
        fi
    fi

    # Cleanup
    rm -rf "$test_dir" 2>/dev/null || true

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

# Calculate the depth of a directory tree (max depth) - OPTIMIZED
# Uses fd with --max-depth and wc -l instead of bash loops
calculate_depth() {
    local src_dir="$1"
    local max_depth=0

    # Find deepest directory using fd's depth info
    # Output format: depth path, we take the max depth
    max_depth=$(fd --type directory --min-depth 1 --max-depth 100 . "$src_dir" 2>/dev/null | \
        sed "s|^[^/]*||" | tr -cd '/' | wc -L)

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
            log "Backup at $HOSTNAME @ $DATE: Lock file $LOCK_FILE is present; assume the previous backup is still running; exit"
            echo "FYI" | mailx -s "Backup at $HOSTNAME @ $DATE: Lock file $LOCK_FILE is present; assume the previous backup is still running; exit"  ${ADMIN_EMAIL}
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
    local task_dir="$4"
    local rsync_opts="$5"

    # Create a task directory with unique task files
    rm -rf "$task_dir"
    mkdir -p "$task_dir"

    # Add source directory itself as a task (for files directly in source)
    local task_file="${task_dir}/task_$(printf '%06d' 0)"
    echo "0|$src_dir|$dest_dir|$rsync_opts" > "$task_file"
    local task_id=1

    # OPTIMIZED: Use fd to get all directories at once, calculate depths using sed/awk
    # instead of bash string manipulation in a loop
    local src_len=${#src_dir}

    # Get all directories with their depth in one fd pass
    while IFS= read -r dir; do
        # Calculate depth by counting slashes after removing src_dir prefix
        local rel_path="${dir#$src_dir}"
        rel_path="${rel_path#/}"

        # Use parameter expansion to count slashes (faster than tr | wc)
        local rel_depth="${rel_path//[^\/]/}"
        rel_depth=${#rel_depth}

        # Only include directories up to and including the specified depth
        if [[ $rel_depth -le $depth ]]; then
            # Ensure dest_path has proper path separator
            local dest_path
            if [[ "$rel_path" == "" ]]; then
                dest_path="$dest_dir"
            else
                dest_path="$dest_dir/$rel_path"
            fi
            task_file="${task_dir}/task_$(printf '%06d' $task_id)"
            echo "$rel_depth|$dir|$dest_path|$rsync_opts" > "$task_file"
            echo  task=$task_id, rel_depth=$rel_depth: rsync $rsync_opts $dir $dest_path    >> "$GLOBAL_LOG"
            ((task_id++)) || true
        fi
    done < <(fd --hidden --type directory --min-depth 1 . "$src_dir")
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
    local task_basename="${task_file##*/}"
    # Handle both task_XXXXX and task_XXXXX.processing naming
    local worker_id="${task_basename%.processing}"
    worker_id="${worker_id#task_}"
    local log_file="$log_dir/task_${worker_id}.log"

    # OPTIMIZED: Parse destination once and cache the result
    local remote_host="" remote_path="" is_remote=0
    if [[ "$dest" =~ ^([^:]+):(.+)$ ]]; then
        remote_host="${BASH_REMATCH[1]}"
        remote_path="${BASH_REMATCH[2]}"
        is_remote=1
    fi

    # Run rsync
    local rsync_cmd="rsync $rsync_opts"

    # Handle the root task (level 0) specially - non-recursive using --dirs
    # This backs up files and immediate subdirectories of the source folder (depth 1 only)
    # For subdirectories: -r for shallower (to include full subtree), -r for max depth
    if [[ "$level" -eq 0 ]]; then
        rsync_cmd="$rsync_cmd --dirs"
    elif [[ "$level" -lt "$max_depth" ]]; then
        rsync_cmd="$rsync_cmd -r"
    else
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

    # Handle remote destination - only build this once if remote
    if [[ $is_remote -eq 1 ]]; then
        # Escape path for shell execution on remote host
        local escaped_remote_path
        escaped_remote_path=$(printf '%q' "$remote_path")
        rsync_cmd="$rsync_cmd --rsync-path=\"mkdir -p $escaped_remote_path && rsync\""
        rsync_cmd="$rsync_cmd \"$src/\" \"$dest/\""
    else
        # Local destination - create directory
        mkdir -p "$dest"
        rsync_cmd="$rsync_cmd \"$src/\" \"$dest/\""
    fi

    log_info "Task $worker_id: $rsync_cmd"
    echo "Running: $rsync_cmd" >> "$log_file"
    eval "$rsync_cmd" >> "$log_file" 2>&1
    return $?
}

run_worker_pool() {
    local task_dir="$1"
    local jobs="$2"
    local log_dir="$3"
    local dry_run="$4"
    local max_depth="$5"
    local rsync_opts="$6"

    # Store running PIDs
    local -a running_pids=()
    local task_count=0
    local total_tasks=0

    # Count total tasks first
    total_tasks=$(find "$task_dir" -name "task_*" -type f 2>/dev/null | wc -l)

    # Exit early if no tasks
    if [[ $total_tasks -eq 0 ]]; then
        return 0
    fi


    while true; do
        # OPTIMIZED: Get next available task using ls with numeric sort for ordering
        # This is faster than find + head for small task counts
        # Only get files that don't have .processing suffix (those are being worked on)
        task_file=""
        if [[ ${#running_pids[@]} -lt $jobs ]]; then
            task_file=$(ls -1 "$task_dir"/task_* 2>/dev/null | grep -v '\.processing$' | head -n 1) || true
        fi

        if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
            # No more tasks to claim, check if we're done
            local remaining
            remaining=$(find "$task_dir" -name "task_*" -type f ! -name "*.processing" 2>/dev/null | wc -l)
            if [[ $remaining -eq 0 ]]; then
                break
            fi
            # Wait for a worker to complete before trying again
            if [[ ${#running_pids[@]} -gt 0 ]]; then
                # Busy-wait with sleep for job completion
                local new_pids=()
                for pid in "${running_pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        wait "$pid" 2>/dev/null || true
                    else
                        new_pids+=("$pid")
                    fi
                done
                running_pids=("${new_pids[@]}")
                # Sleep briefly before checking for more tasks
                sleep 0.05
            else
                break
            fi
            continue
        fi

        # Try to claim the task by renaming it atomically
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
            local new_pids=()
            for pid in "${running_pids[@]}"; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    wait "$pid" 2>/dev/null || true
                    # Skip this pid (it's done)
                else
                    new_pids+=("$pid")
                fi
            done
            running_pids=("${new_pids[@]}")
        fi
    done

    # Wait for all remaining jobs to complete
    for pid in "${running_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Clean up task directory (including any .processing files)
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

    # OPTIMIZED: Combine all error patterns into a single grep command
    # Error patterns (case-insensitive) - combined into extended regex
    local error_patterns="rsync error:|error:"

    # Single pass through all logs looking for errors
    local error_files=""
    for log_file in "$log_dir"/task_*.log; do
        [[ -f "$log_file" ]] || continue

        # Count error occurrences in one pass
        local matches
        matches=$(grep -iE "$error_patterns" "$log_file" 2>/dev/null | wc -l)

        if [[ $matches -gt 0 ]]; then
            log_error "Errors found in $log_file"
            error_count=$((error_count + matches))
            # Append error lines to global log
            while IFS= read -r line; do
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $line" >> "$GLOBAL_LOG"
            done < <(grep -i "error:" "$log_file" 2>/dev/null || true)
        fi
    done

    # Also check worker_*.log files for compatibility
    for log_file in "$log_dir"/worker_*.log; do
        [[ -f "$log_file" ]] || continue

        local matches
        matches=$(grep -iE "$error_patterns" "$log_file" 2>/dev/null | wc -l)

        if [[ $matches -gt 0 ]]; then
            log_error "Errors found in $log_file"
            error_count=$((error_count + matches))
            while IFS= read -r line; do
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $line" >> "$GLOBAL_LOG"
            done < <(grep -i "error:" "$log_file" 2>/dev/null || true)
        fi
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

    # Create log directory (keep previous global logs from other jobs)
    mkdir -p "$LOG_DIR"
    rm -f "$LOG_DIR"/worker_*.log
    rm -f "$LOG_DIR"/task_*.log "$LOG_DIR"/task_*.log.*  # Clean task logs only
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
        task_queue=$(mktemp -d)
        build_task_queue "$src" "$dest" "$depth" "$task_queue" "$rsync_opts"

        local task_count
        task_count=$(find "$task_queue" -name "task_*" -type f 2>/dev/null | wc -l)
        log_info "Built task queue with $task_count tasks"

        # Run worker pool
        run_worker_pool "$task_queue" "$jobs" "$LOG_DIR" "$dry_run" "$depth" "$rsync_opts"

        # Clean up task queue directory
        rm -rf "$task_queue" 2>/dev/null || true

        # Clean up any temporary files in destination
        # Rsync may create temporary files like .FILENAME.XXXXXX during transfers
        if [[ "$dest" =~ ^([^:]+): ]]; then
            # Remote destination - cleanup via SSH
            local remote_dest_path="${dest#*:}"
            ssh -o BatchMode=yes "${dest%%:*}" "find '$remote_dest_path' -name '.*' -type f -delete 2>/dev/null || true" 2>/dev/null || true
        else
            # Local destination - direct cleanup
            find "${dest}" -name '.*' -type f -delete 2>/dev/null || true
        fi
    done

    # Clean up any leftover .tasks directories from failed runs
    rm -rf /tmp/*.tasks 2>/dev/null || true
    rm -rf /tmp/tmp.*.tasks 2>/dev/null || true

    # Clean up any leftover .processing files in log directory from failed runs
    rm -f "$LOG_DIR"/*.processing 2>/dev/null || true
    rm -f "$LOG_DIR"/task_*.log.processing 2>/dev/null || true

    # Analyse logs for errors (ignore errors to allow script to complete)
    analyse_logs "$LOG_DIR" || true

    # Log job end time
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] --------------------------" >> "$GLOBAL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Job ended at $(date)" >> "$GLOBAL_LOG"
}

main "$@"
