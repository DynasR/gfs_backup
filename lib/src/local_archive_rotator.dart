/// Rotating local archive — the "even if the cloud is never set up,
/// there are still rotating full backups on this device" safety net.
///
/// Same GFS retention shape as the cloud rotation (it reuses
/// [GfsRetentionPlan]: 7 daily / 4 weekly / 6 monthly), but generations go
/// to a caller-supplied sink rather than to a [BackupBackend]: four
/// callbacks, nothing else. Point them at a `Directory` on desktop, at a
/// Storage Access Framework writer on Android, at a map in a test — the
/// rotator itself touches nothing. No filesystem, no platform channel, no
/// network, no dependencies.
///
/// Generations are written exactly as handed over, encrypted or not: if
/// you want sealed archives, seal inside the `snapshotBytes` callback.
library;

import 'dart:typed_data';

import 'backup_backend.dart';
import 'dated_file_name.dart';
import 'gfs_retention.dart';

/// Result of a single [LocalArchiveRotator.archiveNow] run.
class LocalArchiveRunResult {
  /// Wraps the outcome of one run.
  const LocalArchiveRunResult({
    required this.writtenFileName,
    required this.kept,
    required this.purged,
  });

  /// File name written for today's generation
  /// (`<filePrefix>-<yyyy-mm-dd><fileSuffix>`).
  final String writtenFileName;

  /// Every retained generation, with the tier(s) that justify keeping it.
  final List<RetainedBackup> kept;

  /// File names ACTUALLY deleted by this run. A generation the plan
  /// purged but whose delete callback returned `false` is absent from this
  /// list even though [LocalArchiveRotator.archiveNow] attempted it — a sink that swallows
  /// its own exception and reports failure instead of throwing must not be
  /// credited with a deletion it did not perform.
  final List<String> purged;
}

/// Writes one full snapshot per day into a local sink, then applies the
/// GFS retention plan to everything already there.
class LocalArchiveRotator {
  /// Every collaborator is a callback, [now] included, so the rotator can
  /// be driven across any span of dates in a test without touching a disk.
  LocalArchiveRotator({
    required this.filePrefix,
    required Future<Uint8List> Function() snapshotBytes,
    required Future<void> Function(String fileName, Uint8List bytes) write,
    required Future<List<String>> Function() list,
    required Future<bool> Function(String fileName) delete,
    this.fileSuffix = '.sqlite',
    DateTime Function()? now,
  })  : _snapshotBytes = snapshotBytes,
        _write = write,
        _list = list,
        _delete = delete,
        _now = now ?? DateTime.now;

  /// Filename prefix for archive generations
  /// (`<filePrefix>-<yyyy-mm-dd><fileSuffix>`). A name that does not match
  /// that exact shape is foreign and never purged, so the archive folder
  /// can safely hold more than this rotator's own files.
  final String filePrefix;

  /// Filename suffix, `.sqlite` by default — the expected producer
  /// being a `VACUUM INTO`-style whole-database snapshot.
  final String fileSuffix;

  /// Produces today's full snapshot bytes.
  final Future<Uint8List> Function() _snapshotBytes;

  /// Writes (or overwrites) the named file in the archive location: a
  /// `File(...)` write on desktop, a Storage Access Framework write on
  /// Android, a map assignment in a test.
  final Future<void> Function(String fileName, Uint8List bytes) _write;

  /// Lists the file names currently present in the archive location.
  /// Foreign names (not matching `<filePrefix>-<yyyy-mm-dd><fileSuffix>`)
  /// are ignored — never purged.
  final Future<List<String>> Function() _list;

  /// Deletes the named file from the archive location. Must return `true`
  /// only if the file was actually deleted — a sink that swallows its
  /// own exception and returns `false` on failure must not be credited
  /// with a successful purge just because it did not throw.
  final Future<bool> Function(String fileName) _delete;

  final DateTime Function() _now;

  /// Writes today's generation (overwriting a same-day one, so re-running
  /// on the same day is idempotent, not duplicative), then applies the GFS
  /// retention plan to everything present and deletes what no tier
  /// retains.
  Future<LocalArchiveRunResult> archiveNow() async {
    final now = _now();
    final today = DateTime.utc(now.year, now.month, now.day);

    final bytes = await _snapshotBytes();
    final todayName = fileNameFor(today);
    await _write(todayName, bytes);

    final names = await _list();
    final presentByDate = <DateTime, String>{};
    for (final name in names) {
      final date = parseDateFromFileName(name);
      if (date != null) presentByDate[date] = name;
    }
    // Today's generation was just written; make sure it participates in
    // the plan even if the sink's `list` is stale/eventually consistent.
    presentByDate[today] = todayName;

    final plan = GfsRetentionPlan.compute(
      now: today,
      presentDates: presentByDate.keys,
    );

    final purged = <String>[];
    for (final date in plan.purge) {
      final name = presentByDate[date];
      if (name == null) continue;
      final deleted = await _delete(name);
      if (deleted) purged.add(name);
    }

    return LocalArchiveRunResult(
      writtenFileName: todayName,
      kept: plan.keep,
      purged: purged,
    );
  }

  /// `<filePrefix>-<yyyy-mm-dd><fileSuffix>` for [date].
  String fileNameFor(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '$filePrefix-${date.year}-${two(date.month)}-${two(date.day)}'
        '$fileSuffix';
  }

  /// Parses the calendar date out of an archive file name, or `null` for
  /// any name that doesn't match the exact
  /// `<filePrefix>-<yyyy-mm-dd><fileSuffix>` shape.
  ///
  /// Shares its rule with `GfsBackupService.parseDateFromFileName`: the
  /// two rotations cannot disagree about what a name means.
  DateTime? parseDateFromFileName(String name) =>
      parseDatedFileName(name, prefix: filePrefix, suffix: fileSuffix);
}
