# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a parallel rsync backup system:

1. **ai-backup.sh** - Bash implementation with parallel workers

## Key Architecture

**Three-phase execution:**
1. **Expand** - Walks directory tree to build task queue (one task per directory up to --depth, plus root folder)
2. **Pool** - Drives tasks through a controlled worker pool (max concurrency defined by --jobs)
3. **Analyse** - Scans task logs for rsync errors

**Worker strategy:**
- Root task (level 0): Recursive (`-r`) to include all files and subdirectories
- Non-recursive (`--dirs`) for directories shallower than MAX_DEPTH
- Recursive (`-r`) for directories at exactly MAX_DEPTH (to cover full subtree)

**Job limiting:**
- `--jobs N` limits the maximum number of concurrent rsync operations
- Tasks are claimed atomically using `mv` on task files
- Running PIDs are tracked and controlled to respect the job limit

## Commands

```bash
# Run the Bash version
./ai-backup.sh [--dry-run] [--jobs N] [--depth N]

# Validate syntax
bash -n ai-pbkp-lstr.sh

# Show help
./ai-pbkp-lstr.sh --help
```

## Configuration

Key environment/script constants:
- `BACKUP_JOBS` - Array of "source|destination" pairs (e.g., `./src|/dest ./src2|server:/path`)
- `RSYNC_OPTS` - rsync flags: `-lptgoDzhHAx --delete -v`
- `WEEKDAY_FILTER` / `SATURDAY_FILTER` - Directory patterns to exclude based on day of week
- `LOG_DIR` - Per-task logs: `./bkplog`
- `GLOBAL_LOG` - Job log with start/end times and error summary

## Notes

- Each source directory must contain a `README` file (used as a checkpoint/check mechanism)
- Lock file `/tmp/.running_backup_ai-pbkp-lstr` prevents concurrent runs
- Error patterns are matched case-insensitively in log analysis
- Host name is not restricted (pbkp check removed)
- Root source folder files are included via a special level-0 task

## Important

- **Do not commit test folders** (test_data, test_backup, test_backup4, test_remote_backup) - these are generated dynamically
- **Do not commit log folders** (bkplog) - these contain temporary backup logs

## Development Rules

- Document all notable changes and git commits in `CHANGELOG.md`
