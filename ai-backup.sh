#!/bin/bash
#
# Parallel rsync backup system
# Implements three-phase execution:
#   1. Expand - Walk directory tree to build task queue
#   2. Pool   - Drive tasks through fixed-size worker pool
#   3. Analyse - Scan task logs for rsync errors
#

set -euo pipefail

# ====== Configuration =====
ADMIN_EMAIL="admin@example.com"
DATE="$(date +%Y%m%d)"
HOSTNAME="$(hostname -s)"
# Source|destination pairs (array of "source;destination" strings)
# Default: local backup and remote backup to localhost
# Remote format: server:path (rsync will use SSH for remote destinations)
# Example: BACKUP_JOBS=("./src|/dest" "server:/path|/local/dest") ./ai-backup.sh
# Or use a wrapper script that sets the array before sourcing
# Note: Array cannot be exported from shell environment, so use string fallback
#
BACKUP_JOBS=("${BACKUP_JOBS[@]+"${BACKUP_JOBS[@]}"}")
if [[ ${#BACKUP_JOBS[@]} -eq 0 ]] && [[ -n "${BACKUP_JOBS:-}" ]]; then
    # BACKUP_JOBS is a string (from export), parse it
    IFS=';' read -ra BACKUP_JOBS <<< "${BACKUP_JOBS:-}"
fi

if [[ ${#BACKUP_JOBS[@]} -eq 0 ]]; then
    #BACKUP_JOBS=("./test_data|localhost:$PWD/test_remote_backup/test_data")
    BACKUP_JOBS=("./test_data|$PWD/test_remote_backup/test_data")
fi

# rsync flags
RSYNC_OPTS="-lptgoDzhHAs --delete-after -v --numeric-ids"
#
SCRIPT_NAME=$(basename "$0" .sh)

# Directory patterns to exclude (weekdays vs Saturday)
WEEKDAY_FILTER="climlab_scratch"
SATURDAY_FILTER="314159027"

# Log directory - default to user's home if not explicitly set
LOG_DIR="${LOG_DIR:-/local/home/root/lstrbkp/bkplog-${SCRIPT_NAME}}"

# Cached xattr support results: keyed by destination path
declare -A XATTR_CACHE=()

# Cached remote core counts: keyed by hostname
declare -A CORE_CACHE=()

# ====== Helper Functions =====

# Function to get core count from a host (local or remote) - with caching
get_host_cores() {
    local host="$1"
    if [[ -n "${CORE_CACHE[$host]+x}" ]]; then
        echo "${CORE_CACHE[$host]}"
        return
    fi
    local cores=4
    if [[ "$host" == "localhost" ]] || [[ "$host" == "127.0.0.1" ]] || [[ "$host" == "$(hostname)" ]]; then
        cores=$(nproc 2>/dev/null || echo 4)
    else
        # SSH to remote host and get core count
        cores=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "nproc" 2>/dev/null | head -1 || true)
        cores="${cores:-4}"
    fi
    # Validate cores is a positive integer
    if [[ "$cores" =~ ^[0-9]+$ ]] && [[ "$cores" -gt 0 ]]; then
        CORE_CACHE[$host]=$cores
        echo "$cores"
    else
        CORE_CACHE[$host]=4
        echo 4
    fi
}

# Check if destination supports rsync -X option (extended attributes)
# Returns "yes" if supported, "no" otherwise
# Result is cached to avoid repeated SSH/hardware probes
check_rsync_xattr_support() {
    local dest_dir="$1"

    # Return cached result if available
    if [[ -n "${XATTR_CACHE[$dest_dir]+x}" ]]; then
        echo "${XATTR_CACHE[$dest_dir]}"
        return
    fi

    local result="no"

    # Check if rsync supports -X first
    local rsync_help
    rsync_help=$(rsync --help 2>&1 | grep '\-X, --xattrs' || true)
    if [[ -z "$rsync_help" ]]; then
        XATTR_CACHE[$dest_dir]="no"
        log_info "rsync does not support -X"
        echo "no"
        return 0
    fi

    # Parse destination to check if remote
    local remote_host=""
    if [[ "$dest_dir" =~ ^([^:]+):(.+)$ ]]; then
        remote_host="${BASH_REMATCH[1]}"
        dest_dir="${BASH_REMATCH[2]}"
    fi

    local test_dir="${dest_dir}/.rsync_xattr_test_$$"

    # Create test directory (local or remote)
    if [[ -z "$remote_host" ]]; then
        # Local destination
        if ! mkdir -p "$test_dir" 2>/dev/null; then
            XATTR_CACHE[$dest_dir]="no"
            log_info "Cannot create test directory $test_dir"
            echo "no"
            return 0
        fi
    else
        # Remote destination - escape single quotes for SSH command
        local escaped_dir
        escaped_dir="${dest_dir//\'/\'\\\'\'}"
        if ! ssh -o BatchMode=yes "$remote_host" "mkdir -p '${escaped_dir}'" 2>/dev/null; then
            XATTR_CACHE[$dest_dir]="no"
            log_info "Cannot create test directory $test_dir on remote host"
            echo "no"
            return 0
        fi
    fi

    # Try to set an extended attribute
    if [[ -z "$remote_host" ]]; then
        # Local
        if setfattr -n user.test -v "test" "$test_dir" 2>/dev/null; then
            if rsync -X --dry-run "$test_dir"/ "$test_dir"/backup >/dev/null 2>&1; then
                result="yes"
            fi
        fi
    else
        # Remote - use SSH to run commands
        local escaped_dir
        escaped_dir="${dest_dir//\'/\'\\\'\'}"
        local escaped_test
        escaped_test="${test_dir//\'/\'\\\'\'}"
        if ssh -o BatchMode=yes "$remote_host" "setfattr -n user.test -v 'test' '${escaped_test}'" 2>/dev/null; then
            if ssh -o BatchMode=yes "$remote_host" "rsync -X --dry-run '${escaped_test}'/' '${escaped_test}'/backup" >/dev/null 2>&1; then
                result="yes"
            fi
        fi
    fi

    # Cleanup (local or remote)
    if [[ -z "$remote_host" ]]; then
        rm -rf "$test_dir" 2>/dev/null || true
    else
        local escaped_test
        escaped_test="${test_dir//\'/\'\\\'\'}"
        ssh -o BatchMode=yes "$remote_host" "rm -rf '${escaped_test}'" 2>/dev/null || true
    fi

    # Cache and return result
    XATTR_CACHE[$dest_dir]="$result"
    log_info "Result: $result"
    echo "$result"
}

# Calculate minimum cores across all hosts in BACKUP_JOBS
calculate_min_cores() {
    local min_cores
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
LOCK_FILE="/tmp/.running_backup_${SCRIPT_NAME}"

# Global log file (defined after SCRIPT_NAME is set)
GLOBAL_LOG="${LOG_DIR}/${SCRIPT_NAME}_$(date '+%Y%m%d_%H%M%S').sum"

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

# ====== Logging =====
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$GLOBAL_LOG"
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }

# Check if today is Saturday (ISO: 1=Mon ... 7=Sun, 6=Saturday)
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

# Escape single quotes in a string for safe embedding in SSH/eval commands
escape_single_quotes() {
    local str="$1"
    echo "${str//\'/\'\\\'\'}"
}

# Calculate the depth of a directory tree (max depth) - OPTIMIZED
# Uses fd with --max-depth and wc -l instead of bash loops
calculate_depth() {
    local src_dir="$1"
    local max_depth=0

    # Find deepest directory using fd's depth info
    max_depth=$(fd --type directory --min-depth 1 --max-depth 100 . "$src_dir" 2>/dev/null | \
        sed "s|^[^/]*||" | tr -cd '/' | wc -L)

    # Return at least 1, or 0 if no directories found
    if [[ $max_depth -eq 0 ]]; then
        echo 1
    else
        echo "$max_depth"
    fi
}

# ====== Lock Management =====

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

# ====== Phase 1: Expand - Build Task Queue =====

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
    local max_depth=$((depth + 1))
    local SRCFILTER
    SRCFILTER=$(get_filter)

    # Anchor the grep filter to directory boundaries (^ or / prefix, / or $ suffix)
    # so that partial matches (e.g. "myclimlab_scratch_foo") are not excluded
    local filter_pattern="(^|/)$SRCFILTER(/|$)"

    while IFS= read -r dir; do
        # Calculate depth by counting slashes after removing src_dir prefix
        local rel_path="${dir#$src_dir}"
        rel_path="${rel_path#/}"
        # Strip trailing slash if present
        rel_path="${rel_path%/}"

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
            # Convert source path to absolute path to avoid issues with rsync
            local abs_src_dir
            abs_src_dir=$(cd "$(dirname "$dir")" && pwd)/$(basename "$dir")
            task_file="${task_dir}/task_$(printf '%06d' $task_id)"
            echo "$rel_depth|$abs_src_dir|$dest_path|$rsync_opts" > "$task_file"
            ((task_id++)) || true
        fi
    done < <(fd -u --type directory --min-depth 1 --max-depth "$max_depth" . "$src_dir" 2>/dev/null | sort | grep -vE "$filter_pattern" || true)
}

# ====== Phase 2: Pool - Worker Pool Management =====

# Track failed tasks within this pool run
FAILED_TASKS=""
ERROR_COUNT=0

process_task() {
    local task_file="$1"
    local log_dir="$2"
    local max_depth="$3"

    local task
    task=$(cat "$task_file")
    rm -f "$task_file"

    local level src dest rsync_opts
    IFS='|' read -r level src dest rsync_opts <<< "$task"

    # Use worker_id based on task file number for consistent logging
    local task_basename="${task_file##*/}"
    # Handle both task_XXX and task_XXX.processing naming
    local worker_id="${task_basename%.processing}"
    worker_id="${worker_id#task_}"
    local log_file="$log_dir/task_${worker_id}.log"

    # Parse destination once and cache the result
    local remote_host="" remote_path="" is_remote=0
    if [[ "$dest" =~ ^([^:]+):(.+)$ ]]; then
        remote_host="${BASH_REMATCH[1]}"
        remote_path="${BASH_REMATCH[2]}"
        is_remote=1
    fi

    # Handle the root task (level 0) specially - non-recursive using --dirs
    # This backs up files and immediate subdirectories of the source folder (depth 1 only)
    # For subdirectories: -r for shallower (to include full subtree), -r for max depth
    if [[ "$level" -lt "$max_depth" ]]; then
        rsync_opts="$rsync_opts --dirs"
    else
        rsync_opts="$rsync_opts -r"
    fi

    # Build rsync options as string
    local rsync_opts_str="$rsync_opts"

    # Log the command (with rsync-path for remote)
    if [[ $is_remote -eq 1 ]]; then
        log_info "Task $worker_id: rsync $rsync_opts_str '$src/' '$dest'"
        local escaped_path
        escaped_path=$(escape_single_quotes "$remote_path")
        echo "Running: ssh -n $remote_host \"mkdir -p '$escaped_path' \" " >> "$log_file"
        echo "Running: rsync $rsync_opts_str '$src/' '$dest'" >> "$log_file"
    else
        log_info "Task $worker_id: rsync $rsync_opts_str '$src/' '$dest'"
        echo "Running: rsync $rsync_opts_str '$src/' '$dest'" >> "$log_file"
    fi
    echo "DEBUG: remote_path='$remote_path', is_remote=$is_remote" >> "$log_file"

    # Execute rsync with proper quoting of options array
    local rsync_args
    eval "rsync_args=($rsync_opts_str)"

    local result=0
    if [[ $is_remote -eq 1 ]]; then
        # Remote destination - create directory first via SSH, then rsync
        local escaped_path
        escaped_path=$(escape_single_quotes "$remote_path")
        ssh -n "$remote_host" "mkdir -p '$escaped_path'" 2>/dev/null || true
        rsync "${rsync_args[@]}" "$src/" "$dest/" >> "$log_file" 2>&1 || result=$?
    else
        # Local destination - create directory
        mkdir -p "$dest"
        rsync "${rsync_args[@]}" "$src/" "$dest/" >> "$log_file" 2>&1 || result=$?
    fi

    echo "Exit status: $result" >> "$log_file"

    # Propagate exit code so caller's wait() picks it up
    return $result
}

run_worker_pool() {
    local task_dir="$1"
    local jobs="$2"
    local log_dir="$3"
    local max_depth="$4"
    local rsync_opts="$5"

    # Track failed tasks for the caller
    local -a failed_tasks=()

    # Store running PIDs
    local -a running_pids=()
    local -a running_task_files=()
    local task_count=0
    local total_tasks=0

    # Count total tasks first
    total_tasks=$(find "$task_dir" -name "task_*" -type f 2>/dev/null | wc -l)

    # Exit early if no tasks
    if [[ $total_tasks -eq 0 ]]; then
        log_info "run_worker_pool: total_tasks=$total_tasks, return 0"
        return 0
    fi

    while true; do
        # Get next available task using find (avoids 'Argument list too long' vs ls)
        # Only get files that don't have .processing suffix (those are being worked on)
        local task_file=""
        if [[ ${#running_pids[@]} -lt $jobs ]]; then
            task_file=$(find "$task_dir" -name "task_*" -type f ! -name "*.processing" | head -n 1) || true
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
                local new_task_files=()
                local i=0
                for pid in "${running_pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        if ! wait "$pid" 2>/dev/null; then
                            # Track which task failed
                            failed_tasks+=("${running_task_files[$i]}")
                        fi
                    else
                        new_pids+=("$pid")
                        new_task_files+=("${running_task_files[$i]}")
                    fi
                    ((i++)) || true
                done
                running_pids=("${new_pids[@]+"${new_pids[@]}"}")
                running_task_files=("${new_task_files[@]+"${new_task_files[@]}"}")
                # Sleep briefly before checking for more tasks
                sleep 0.05
            else
                break
            fi
            continue
        fi

        # Try to claim the task by creating an atomic hard link
        # ln fails with EEXIST if the file already exists (other worker claimed it first)
        local task_link="${task_dir}/.claim_$$_${RANDOM}"
        if ln "$task_file" "$task_link" 2>/dev/null; then
            # Successfully claimed - rename .claim_X to .processing for visibility
            rm -f "$task_link"
            if mv "$task_file" "${task_file}.processing" 2>/dev/null; then
                task_file="${task_file}.processing"
            else
                # Race: another worker claimed it between ln and mv
                rm -f "$task_link"
                sleep 0.05
                continue
            fi
        else
            # Task was already claimed by another process, wait briefly
            sleep 0.05
            continue
        fi

        # Start task in background
        ( process_task "$task_file" "$log_dir" "$max_depth" ) &
        local pid=$!
        running_pids+=($pid)
        running_task_files+=("$task_file")
        ((task_count++)) || true

        # If we've hit the job limit, wait for at least one to complete
        if [[ ${#running_pids[@]} -ge $jobs ]]; then
            # Wait for any one job to complete
            local new_pids=()
            local new_task_files=()
            local i=0
            for pid in "${running_pids[@]}"; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    if ! wait "$pid" 2>/dev/null; then
                        failed_tasks+=("${running_task_files[$i]}")
                    fi
                else
                    new_pids+=("$pid")
                    new_task_files+=("${running_task_files[$i]}")
                fi
                ((i++)) || true
            done
            running_pids=("${new_pids[@]+"${new_pids[@]}"}")
            running_task_files=("${new_task_files[@]+"${new_task_files[@]}"}")
        fi
    done

    # Wait for all remaining jobs to complete
    local had_errors=0
    for pid in "${running_pids[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            had_errors=1
        fi
    done

    # Report failed tasks to the caller
    if [[ $had_errors -eq 1 ]] || [[ ${#failed_tasks[@]} -gt 0 ]]; then
        for ft in "${failed_tasks[@]}"; do
            log_error "Task failed: $ft"
        done
        return 1
    fi

    return 0
}

# ====== Phase 3: Analyse - Scan Logs for Errors =====

analyse_logs() {
    local log_dir="$1"
    local error_count=0

    log_info "Scanning logs for errors..."

    # Single pass through all logs: collect errors and count in one grep
    local error_lines=()

    for log_file in "$log_dir"/task_*.log "$log_dir"/worker_*.log; do
        [[ -f "$log_file" ]] || continue

        # Count matches in one pass
        local matches
        matches=$(grep -ciE "rsync error:|error:" "$log_file" 2>/dev/null || true)

        if [[ "$matches" -gt 0 ]]; then
            log_error "Errors found in $log_file ($matches match(es))"
            error_count=$((error_count + matches))
            # Append error lines to global log (extracted from the same grep above)
            local file_error_lines
            file_error_lines=$(grep -iE "rsync error:|error:" "$log_file" 2>/dev/null || true)
            if [[ -n "$file_error_lines" ]]; then
                while IFS= read -r line; do
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $line" >> "$GLOBAL_LOG"
                done <<< "$file_error_lines"
            fi
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

# ====== Signal Handling =====

# Forward signals to child processes and clean up
SIGNAL_RECEIVED=0
handle_signal() {
    SIGNAL_RECEIVED=1
    log_info "Received signal, cleaning up..."
    # Kill all remaining child processes
    local pids
    pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        wait 2>/dev/null || true
    fi
    release_lock
    exit 1
}

trap handle_signal INT TERM

# ====== Help and Usage =====

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

# Check if path is on Lustre filesystem with lustre.lov xattr
check_lustre_xattr() {
    local path="$1"
    local result="no"

    # Get the mount point for the path
    local mount_point
    mount_point=$(df "$path" 2>/dev/null | tail -1 | awk '{print $6}')

    # Check if it's a Lustre filesystem
    if mount | grep -q " lustre " && mount | grep "$mount_point" | grep -q " lustre "; then
        result="yes"
    fi
    log_info "Lustre lustre.lov xattr check for $path, result= $result"
    echo "$result"
}

# Build rsync options based on destination capabilities
# Arguments: dest, lustre_check_at_source (optional)
build_rsync_options() {
    local dest="$1"
    local lustre_at_src="${2:-no}"
    local opts="$RSYNC_OPTS"

    # Check if destination supports -X (extended attributes) - result is cached
    local xattr_support
    xattr_support=$(check_rsync_xattr_support "$dest")
    if [[ "$xattr_support" == "yes" ]] && [[ "$lustre_at_src" == "no" ]]; then
        opts="$opts -X"
        log_info "Applying -X for extended attributes preservation"
    else
        log_info "Skipping -X (lustre at source: $lustre_at_src, xattr_support: $xattr_support)"
    fi

    log_info "build_rsync_options:: Opts= $opts"
    echo "$opts"
}

# ====== Main =====

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
    if [ ! -d "$LOG_DIR" ]; then
        /bin/mkdir -p "$LOG_DIR"
    fi
    #
    # Clean task logs only; do not use rm to avoid /bin/rm: Argument list too long error
    find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -delete

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

    local had_pool_errors=0

    # Process each backup job
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r src dest <<< "$job"

        if [[ ! -d "$src" ]]; then
            log_error "Source directory does not exist: $src"
            continue
        fi

        log_info "Processing: $src -> $dest"

        # Check if lustre is detected at source
        local lustre_check
        lustre_check=$(check_lustre_xattr "$src")
        log_info "Lustre check for source $src: $lustre_check"

        # Build rsync options for this destination
        local rsync_opts
        rsync_opts=$(build_rsync_options "$dest" "$lustre_check")
        log_info "Using rsync options: $rsync_opts"

        # Add --dry-run to rsync options if in dry run mode
        if [[ "$dry_run" == "true" ]]; then
            rsync_opts="$rsync_opts --dry-run"
            log_info "Added --dry-run to rsync options"
        fi

        # Build task queue
        local task_queue
        task_queue=$(mktemp -d)
        build_task_queue "$src" "$dest" "$depth" "$task_queue" "$rsync_opts"

        local task_count
        task_count=$(find "$task_queue" -name "task_*" -type f 2>/dev/null | wc -l)
        log_info "Built task queue with $task_count tasks"

        # Run worker pool and track errors
        if ! run_worker_pool "$task_queue" "$jobs" "$LOG_DIR" "$depth" "$rsync_opts"; then
            had_pool_errors=1
        fi

        # Clean up task queue directory (owned by this function call)
        rm -rf "$task_queue" 2>/dev/null || true

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

    # Exit with error if any pool-level failures occurred
    if [[ $had_pool_errors -eq 1 ]]; then
        return 1
    fi
}

main "$@"
