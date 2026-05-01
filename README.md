# aibkp - Parallel Rsync Backup System

A parallel rsync backup system that backs up directory trees using parallel workers.

## Features

- **Three-phase execution**: Expand (build task queue) → Pool (parallel workers) → Analyse (scan for errors)
- **Parallel workers**: Controlled concurrency via `--jobs` option
- **Automatic depth detection**: Calculates max depth of source directories with README files
- **Filter support**: Different exclude patterns for weekdays vs Saturday
- **Lock mechanism**: Prevents concurrent runs
- **Log analysis**: Scans task logs for rsync errors

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
| `RSYNC_OPTS` | rsync flags (default: `-lptgoDzhHAx --delete -v --temp-dir=/tmp/rsync_temp`) |
| `LOG_DIR` | Per-task logs directory (default: `./lstrbkp/aitestlog`) |

## Usage

```bash
# Basic backup (uses 80% of available cores automatically)
./ai-pbkp-lstr.sh

# With custom concurrency and depth
./ai-pbkp-lstr.sh --jobs 8 --depth 3

# Dry run (no changes made)
./ai-pbkp-lstr.sh --dry-run --jobs 4

# Show help
./ai-pbkp-lstr.sh --help
```

## Examples

```bash
# Backup multiple source directories
export BACKUP_JOBS="/data|/backup/data;/projects|/backup/projects"
./ai-pbkp-lstr.sh --jobs 16

# With custom temp directory
export RSYNC_OPTS="-lptgoDzhHAx --delete -v --temp-dir=/tmp/rsync"
./ai-pbkp-lstr.sh --depth 5
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
