/// Grandfather-Father-Son backup retention and rotation, in pure Dart.
///
/// Keeping every backup forever is not a policy, and keeping only the last
/// one is not a backup. GFS is the classic answer: keep the last few days
/// in full, one generation per recent week, one per recent month — recent
/// mistakes are recoverable to the day, old ones to the month, and storage
/// stays bounded.
///
/// This package is that policy, and nothing else:
///
///   * [GfsRetentionPlan] — the decision on its own. Hand it today's date
///     and the dates you currently hold; it answers which to keep, with
///     the tier that justifies each, and which to purge. No I/O, no clock,
///     no dependencies, so a year of rotation replays in a millisecond.
///   * [BackupBackend] — four methods (upload, download, list, delete).
///     The entire contract between this package and your storage.
///   * [GfsBackupService] — snapshot, seal, upload, rotate. Two shapes:
///     classified rotation over one flat folder, or promotion into weekly
///     and monthly folders on the backend itself.
///   * [LocalArchiveRotator] — the same retention against a local sink
///     instead of a backend: four callbacks, so a directory on desktop and
///     a Storage Access Framework tree on Android are the same code.
///
/// Encryption is deliberately out of scope: [GfsBackupService] takes a
/// [BackupSealer] callback and never looks inside the bytes, so the
/// package holds no key, no credential and no opinion about your wire
/// format.
library;

import 'src/backup_backend.dart';
import 'src/gfs_backup_service.dart';
import 'src/gfs_retention.dart';
import 'src/local_archive_rotator.dart';

export 'src/backup_backend.dart';
export 'src/gfs_backup_service.dart';
export 'src/gfs_retention.dart';
export 'src/local_archive_rotator.dart';
