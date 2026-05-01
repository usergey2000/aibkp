# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a parallel rsync backup system:

1. **ai-pbkp-lstr.sh** - Bash implementation with parallel workers

## Key Architecture

**Three-phase execution:**
1. **Expand** - Walks directory tree to build task queue (one task per directory up to --depth)
2. **Pool** - Drives tasks through a fixed-size worker pool (concurrency controlled by --jobs)
3. **Analyse** - Scans task logs for rsync errors

**Worker strategy:**
- Non-recursive (`--dirs`) for directories shallower than MAX_DEPTH
- Recursive (`-r`) for directories at exactly MAX_DEPTH (to cover full subtree)

## Commands

```bash
# Run the Bash version
./ai-pbkp-lstr.sh [--dry-run] [--jobs N] [--depth N]

# Validate syntax
bash -n ai-pbkp-lstr.sh

# Show help
./ai-pbkp-lstr.sh --help
```

## Configuration

Key environment/script constants:
- `BACKUP_JOBS` - Source:destination pairs (semicolon-separated)
- `RSYNC_OPTS` - rsync flags: `-lptgoDzhHAx --delete -v --temp-dir=/lstr/sahara/serguei/temp`
- `SRCFILTER` - Directory patterns to exclude (`climlab_scratch` on weekdays, `314159027` on Saturday)
- `LOG_DIR` - Per-task logs: `./lstrbkp/aitestlog`

## Notes

- Each source directory must contain a `README` file (used as a checkpoint/check mechanism)
- Lock file `/tmp/.running_backup_parallel-rsync-backup` prevents concurrent runs
- Error patterns are matched case-insensitively in log analysis
- Host must be named "pbkp" for execution

## Important

- **Do not commit test folders** (test_data, test_backup, test_backup4, test_remote_backup) - these are generated dynamically and should be removed before committing
