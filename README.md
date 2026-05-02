# aibkp - Parallel Rsync Backup System

A parallel rsync backup system that backs up directory trees using parallel workers with configurable concurrency.

## Features

- **Three-phase execution**: Expand (build task queue) → Pool (parallel workers) → Analyse (scan for errors)
- **Parallel workers**: Controlled concurrency via `--jobs` option (maximum concurrent rsync operations)
- **Automatic depth detection**: Calculates max depth of source directories with README files
- **Filter support**: Different exclude patterns for weekdays vs Saturday
- **Lock mechanism**: Prevents concurrent runs
- **Log analysis**: Scans task logs for rsync errors
- **Root file backup**: Includes files directly in the source folder

## Test Data Generation

The `create_test_data.sh` script generates test directory structures for testing the backup system:

- Creates 10 subfolders with random depths (1-10 levels)
- Each directory contains 1-20 files
- Each folder includes a `README` file as a checkpoint marker
- Outputs structure info showing created folders

Run with: `./create_test_data.sh`

## Configuration

| Environment Variable | Description |
|---------------------|-------------|
| `BACKUP_JOBS` | Source|destination pairs (semicolon-separated) |
| `RSYNC_OPTS` | rsync flags (default: `-lptgoDzhHAx --delete -v`) |
| `LOG_DIR` | Per-task logs directory (default: `./bkplog`) |

## Usage

```bash
# Basic backup (uses 80% of available cores automatically)
./ai-backup.sh

# With custom concurrency and depth
./ai-backup.sh --jobs 8 --depth 3

# Dry run (no changes made)
./ai-backup.sh --dry-run --jobs 4

# Show help
./ai-backup.sh --help
```

## Examples

```bash
# Backup multiple source directories
export BACKUP_JOBS="/data|/backup/data;/projects|/backup/projects"
./ai-backup.sh --jobs 16

# With custom rsync options
export RSYNC_OPTS="-lptgoDzhHAx --delete -v --temp-dir=/tmp/rsync"
./ai-backup.sh --depth 5
```

## Requirements

- Bash 4.0+
- rsync
- fd (fast directory finder)
- flock (for atomic task processing)

## Notes

- Each source directory must contain a `README` file (used as a checkpoint/check mechanism)
- Lock file prevents concurrent runs: `/tmp/.running_backup_<script_name>`
- Error patterns are matched case-insensitively in log analysis
- The `--jobs` option limits the maximum number of concurrent rsync operations
- Files in the root source folder are included in the backup
