/// Daily backup + GFS rotation, driven by the application itself rather
/// than by an external cron job holding its own copy of the credentials:
/// the app already has an authenticated backend and, if it encrypts, the
/// key — which makes it the natural owner of both the write and the
/// rotation that follows.
///
/// Two rotation shapes are supported, because both occur in practice:
///
///   * [GfsRotationMode.flatDaily]: one generation per calendar day in a
///     single flat folder. Retention is *classified* from each file's own
///     date via [GfsRetentionPlan] (7 daily / 4 weekly / 6 monthly), and
///     anything no tier retains is purged. Nothing is ever duplicated: one
///     file can be this week's Sunday and this month's 1st at once.
///
///   * [GfsRotationMode.tieredFolders]: the daily generation is also
///     *promoted* into sibling folders on the backend (Sunday → weekly,
///     1st of the month → monthly), and each of the three folders is
///     pruned to its own retention count. It costs storage, but a copy
///     survives the daily folder being wiped, and the layout reads
///     plainly to a human browsing the backend.
///
/// Encryption is delegated to a caller-supplied [BackupSealer], so this
/// service stays crypto-agnostic: bring your own envelope format, or pass
/// a sealer that returns its input unchanged when you do not encrypt at
/// all. The sealer is handed the generation's ISO date, which is what you
/// need to bind a ciphertext to the day it stands for (as AES-GCM
/// additional authenticated data, for instance).
///
/// Foreign files are never touched: anything in those folders whose name
/// does not match `<filePrefix>-<yyyy-mm-dd>.enc` is invisible to the
/// rotation, and so can never be purged by it.
library;

import 'dart:typed_data';

import 'backup_backend.dart';
import 'gfs_retention.dart';

/// Produces the raw plaintext bytes of one backup generation — a
/// `VACUUM INTO` copy of an SQLite database, a JSON dump, anything.
typedef SnapshotProducer = Future<Uint8List> Function();

/// Seals [plaintext] into whatever wire format you ship. [isoDate] is the
/// `yyyy-mm-dd` of the generation being written, useful as additional
/// authenticated data. An implementation that encrypts must throw when no
/// key is configured rather than fall back: a backup service must never
/// silently upload plaintext.
typedef BackupSealer = Future<Uint8List> Function(
  Uint8List plaintext,
  String isoDate,
);

/// The two rotation shapes [GfsBackupService] can apply.
enum GfsRotationMode {
  /// One generation per day in a single flat folder, rotated by
  /// [GfsRetentionPlan].
  flatDaily,

  /// Backend-side promotion into the weekly and monthly folders, plus
  /// per-folder retention-count pruning.
  tieredFolders,
}

/// Result of a single [GfsBackupService.backupNow] run — everything
/// needed to tell the user what just happened.
class GfsBackupRunResult {
  /// Wraps the outcome of one run.
  const GfsBackupRunResult({
    required this.uploadedPath,
    required this.kept,
    required this.purged,
    this.promotedPaths = const [],
  });

  /// The daily blob path written by this run.
  final String uploadedPath;

  /// Retained generations (with justifying tiers). In
  /// [GfsRotationMode.tieredFolders] this reflects the daily folder only.
  final List<RetainedBackup> kept;

  /// Calendar dates purged from the daily folder by this run.
  final List<DateTime> purged;

  /// Extra backend paths written by tier promotion
  /// ([GfsRotationMode.tieredFolders] only — empty in flat mode).
  final List<String> promotedPaths;
}

/// Writes one backup generation per day to a [BackupBackend], then
/// rotates what is already there. See the library documentation for the
/// two [mode]s.
class GfsBackupService {
  /// Every collaborator is injected, [now] included, so a whole year of
  /// rotation can be replayed in a test in milliseconds.
  GfsBackupService({
    required this.filePrefix,
    required SnapshotProducer snapshotBytes,
    required BackupBackend backend,
    required BackupSealer seal,
    this.mode = GfsRotationMode.flatDaily,
    this.dailyFolder = 'b/daily',
    this.weeklyFolder = 'b/weekly',
    this.monthlyFolder = 'b/monthly',
    this.dailyRetention = 7,
    this.weeklyRetention = 4,
    this.monthlyRetention = 6,
    DateTime Function()? now,
  })  : _snapshotBytes = snapshotBytes,
        _backend = backend,
        _seal = seal,
        _now = now ?? DateTime.now;

  /// Filename prefix for generations (`<filePrefix>-<yyyy-mm-dd>.enc`).
  /// Purely a listing convention: it is what lets the rotation tell its
  /// own files apart from everything else in the folder. A generation that
  /// needs an authenticated identity should carry it inside the envelope
  /// your [BackupSealer] builds, not in its file name.
  final String filePrefix;

  final SnapshotProducer _snapshotBytes;
  final BackupBackend _backend;
  final BackupSealer _seal;

  /// Which of the two rotation shapes this service applies.
  final GfsRotationMode mode;

  /// Folder holding one generation per day. Defaults to `b/daily`: the
  /// three tiers share a `b/` prefix so they sit together, away from
  /// whatever else lives at the backend's root.
  final String dailyFolder;

  /// Folder for Sunday promotions. [GfsRotationMode.tieredFolders] only.
  final String weeklyFolder;

  /// Folder for 1st-of-month promotions.
  /// [GfsRotationMode.tieredFolders] only.
  final String monthlyFolder;

  /// How many daily generations to keep. [GfsRotationMode.tieredFolders]
  /// only — in flat mode the answer comes from [GfsRetentionPlan]
  /// instead.
  final int dailyRetention;

  /// How many weekly generations to keep.
  /// [GfsRotationMode.tieredFolders] only.
  final int weeklyRetention;

  /// How many monthly generations to keep.
  /// [GfsRotationMode.tieredFolders] only.
  final int monthlyRetention;

  final DateTime Function() _now;

  /// Writes today's daily backup blob, then rotates according to [mode].
  /// Always writes on every call — no row-count threshold — because this
  /// exists purely as a point-in-time recovery artifact.
  Future<GfsBackupRunResult> backupNow() async {
    final now = _now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final iso = isoDate(today);
    final plaintext = await _snapshotBytes();
    final envelope = await _seal(plaintext, iso);

    final path = _dailyPath(today);
    await _backend.uploadTo(path, envelope);

    switch (mode) {
      case GfsRotationMode.flatDaily:
        final plan = await rotateNow(now: today);
        return GfsBackupRunResult(
          uploadedPath: path,
          kept: plan.keep,
          purged: plan.purge,
        );
      case GfsRotationMode.tieredFolders:
        final promoted = <String>[];
        // DateTime.weekday: Sunday == 7.
        if (today.weekday == DateTime.sunday) {
          final weeklyPath = '$weeklyFolder/${_fileName(today)}';
          await _backend.uploadTo(weeklyPath, envelope);
          promoted.add(weeklyPath);
        }
        if (today.day == 1) {
          final monthlyPath = '$monthlyFolder/${_fileName(today)}';
          await _backend.uploadTo(monthlyPath, envelope);
          promoted.add(monthlyPath);
        }
        final purgedDates = await _purgeByCount(
          folder: dailyFolder,
          retain: dailyRetention,
        );
        await _purgeByCount(folder: weeklyFolder, retain: weeklyRetention);
        await _purgeByCount(folder: monthlyFolder, retain: monthlyRetention);
        final remaining = await _presentDates(dailyFolder);
        return GfsBackupRunResult(
          uploadedPath: path,
          kept: [
            for (final d in remaining..sort((a, b) => b.compareTo(a)))
              RetainedBackup(date: d, tiers: const {BackupTier.daily}),
          ],
          purged: purgedDates,
          promotedPaths: promoted,
        );
    }
  }

  /// Flat-mode rotation: re-evaluates GFS retention against whatever
  /// `<dailyFolder>/<filePrefix>-*.enc` generations currently exist on the
  /// backend, and purges anything no tier retains. Called by [backupNow]
  /// after every write, and safe to call on its own — a maintenance
  /// action, say — without writing a new generation.
  Future<GfsRetentionPlan> rotateNow({DateTime? now}) async {
    final ref = now ?? _now();
    final today = DateTime.utc(ref.year, ref.month, ref.day);
    final present = await _presentDates(dailyFolder);
    final plan = GfsRetentionPlan.compute(now: today, presentDates: present);
    for (final date in plan.purge) {
      await _backend.deleteFile(_dailyPath(date));
    }
    return plan;
  }

  /// Tiered-mode pruning: deletes every generation under [folder] beyond
  /// the [retain] most recent (by filename, which sorts chronologically
  /// since dates are zero-padded `yyyy-mm-dd`). Safe when the folder has
  /// fewer than [retain] entries (no-op). Returns the purged dates.
  Future<List<DateTime>> _purgeByCount({
    required String folder,
    required int retain,
  }) async {
    final names = (await _backend.listFiles(folder))
        .where((n) => parseDateFromFileName(n) != null)
        .toList()
      ..sort();
    if (names.length <= retain) return const [];
    final toDelete = names.sublist(0, names.length - retain);
    final purged = <DateTime>[];
    for (final name in toDelete) {
      await _backend.deleteFile('$folder/$name');
      final date = parseDateFromFileName(name);
      if (date != null) purged.add(date);
    }
    return purged;
  }

  Future<List<DateTime>> _presentDates(String folder) async {
    final names = await _backend.listFiles(folder);
    return names.map(parseDateFromFileName).whereType<DateTime>().toList();
  }

  String _dailyPath(DateTime date) => '$dailyFolder/${_fileName(date)}';

  String _fileName(DateTime date) => '$filePrefix-${isoDate(date)}.enc';

  /// `yyyy-mm-dd` for [d], zero-padded so names sort chronologically.
  static String isoDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// Parses the calendar date out of `<filePrefix>-<yyyy-mm-dd>.enc`, or
  /// `null` for any name that doesn't match (foreign files are ignored,
  /// never purged).
  DateTime? parseDateFromFileName(String name) {
    final prefix = '$filePrefix-';
    if (!name.startsWith(prefix) || !name.endsWith('.enc')) return null;
    final middle = name.substring(prefix.length, name.length - '.enc'.length);
    final parts = middle.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime.utc(y, m, d);
  }
}
