# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-05

### Changed
- **2026-05-05T15:18:00** - `7f0c923` - Update README.md examples to use --depth 5 --jobs 20
  - Changed usage example to --jobs 20 --depth 5
  - Changed examples section to use --jobs 20 --depth 5
  - Remove rsync options example

### Changed

### Changed
- **2026-05-05T15:12:10** - `5f5c52a` - Update README.md: BACKUP_JOBS array format and ADMIN_EMAIL
  - Changed `BACKUP_JOBS` description to reflect array format
  - Added `ADMIN_EMAIL` to configuration table
  - Updated example to use array syntax

### Changed
- **2026-05-05T15:03:53** - `9589d33` - Change admin email to admin@example.com

### Changed
- **2026-05-05T15:01:53** - `26a3bf9` - Use array for BACKUP_JOBS instead of semicolon-separated string
  - Changed `BACKUP_JOBS` to a proper bash array of "source;destination" pairs
  - Removed `IFS=';' read -ra` parsing in 4 locations
  - Updated default value to use array syntax with conditional assignment
  - Updated help text and comments to reflect array format

## [0.0.0] - 2026-05-02

### Added
- **2026-05-02T00:06:01** - `149f2fa` - Add admin notification on lock conflict

### Changed
- **2026-05-01T23:50:53** - `beb9d36` - Update MAX_JOBS calculation to use 80% of minimum cores

### Changed
- **2026-05-01T23:45:35** - `a838381` - Use head -1 instead of tr -cd for filtering SSH output

### Changed
- **2026-05-01T23:36:31** - `ba7e94f` - Log MAX_JOBS in global log

### Changed
- **2026-05-01T23:34:12** - `cf85d36` - Rename DEFAULT_JOBS to MAX_JOBS

### Changed
- **2026-05-01T23:20:45** - `4990733` - Cap --jobs to DEFAULT_JOBS when specified value exceeds it

### Changed
- **2026-05-01T23:14:20** - `ae7fa31` - Remove cap on DEFAULT_JOBS

### Changed
- **2026-05-01T23:11:39** - `e500581` - Calculate DEFAULT_JOBS from minimum cores across all hosts

### Changed
- **2026-05-01T22:59:54** - `3f64ab3` - Update CLAUDE.md: rename script to ai-backup.sh

### Changed
- **2026-05-01T22:58:11** - `aebd2ec` - Update README.md: rename script to ai-backup.sh

### Changed
- **2026-05-01T22:55:03** - `36fa779` - Rename ai-pbkp-lstr.sh to ai-backup.sh

### Added
- **2026-05-01T19:12:15** - `be3bbb4` - Update backup system with job limiting and root file backup

### Fixed
- **2026-05-01T18:47:14** - `ca942a1` - Fix task_id counter to not fail with set -e

### Changed
- **2026-05-01T18:24:57** - `25274d2` - Cap workers at 20 to avoid task queue race conditions

### Changed
- **2026-05-01T17:38:25** - `bd87743` - Update build_task_queue to include all subfolders up to specified depth

### Changed
- **2026-05-01T17:20:36** - `8b9bab0` - Fix calculate_depth to find max depth of entire tree

### Changed
- **2026-05-01T16:52:48** - `4c85088` - Add error check summary to global log

### Changed
- **2026-05-01T16:50:41** - `82bbfa2` - Log job start/end time, command line and BACKUP_JOBS to global log

### Added
- **2026-05-01T16:46:22** - `0311625` - Add global log file GLOBAL_LOG under LOG_DIR

### Changed
- **2026-05-01T16:31:14** - `f8169ca` - Remove --temp-dir from RSYNC_OPTS

### Changed
- **2026-05-01T16:25:50** - `8b3a114` - Update CLAUDE.md after removing pbkp check

### Changed
- **2026-05-01T16:25:03** - `b88cdf2` - Remove pbkp host check

### Changed
- **2026-05-01T16:23:04** - `3509399` - Check if remote host is reachable before backup

### Changed
- **2026-05-01T16:11:32** - `1e98420` - Update CLAUDE.md with recent code changes

### Changed
- **2026-05-01T16:10:19** - `70a40dc` - Update LOG_DIR and add log folders to CLAUDE.md

### Changed
- **2026-05-01T16:09:26** - `93d4fe2` - Change LOG_DIR to ./bkplog

### Changed
- **2026-05-01T15:58:19** - `df88ed1` - Change BACKUP_JOBS separator from : to |

### Added
- **2026-05-01T15:53:29** - `f89a2de` - Add create_test_data.sh description to README

### Added
- **2026-05-01T15:52:29** - `236ce43` - Add note about not committing test folders

### Changed
- **2026-05-01T15:51:05** - `7bcf9bc` - Remove test data and backup folders

### Changed
- **2026-05-01T15:46:22** - `8e90ed1` - Update create_test_data.sh to create README in test_data root

### Changed
- **2026-05-01T15:24:00** - `9f41db7` - Update default BACKUP_JOBS

### Added
- **2026-05-01T15:14:59** - `934a627` - Support remote backup destinations (remoteserver:path format)

### Added
- **2026-05-01T15:04:43** - `1faea89` - Add README.md with project documentation

### Changed
- **2026-05-01T14:30:01** - `53f50d9` - Update ai-pbkp-lstr.sh configuration

### Changed
- **2026-05-01T14:12:25** - `e8f93ac` - Remove test data and logs

### Added
- **2026-05-01T14:09:10** - `c379426` - Initial commit: Parallel rsync backup system
