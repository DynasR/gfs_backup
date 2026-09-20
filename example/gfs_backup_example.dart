// A complete, runnable tour of the package: `dart run example/…`.
//
// The "backend" here is a map, and the "database snapshot" is a handful of
// bytes — which is the point. Nothing in this package needs a network, a
// filesystem or a key to be exercised end to end.

import 'dart:typed_data';

import 'package:gfs_backup/gfs_backup.dart';

void main() async {
  _theDecisionAlone();
  await _aFullRotation();
  await _aLocalArchive();
}

/// 1. The retention decision on its own — no storage involved at all.
void _theDecisionAlone() {
  final plan = GfsRetentionPlan.compute(
    now: DateTime.utc(2026, 7, 15), // a Wednesday
    presentDates: [
      DateTime.utc(2026, 7, 15), // today
      DateTime.utc(2026, 7, 14), // yesterday
      DateTime.utc(2026, 7, 12), // Sunday of this week
      DateTime.utc(2026, 7, 1), // 1st of this month
      DateTime.utc(2026, 2, 3), // stale: no tier claims it
      DateTime.utc(2026, 7, 16), // tomorrow: never purged, whatever the tiers
    ],
  );

  print('-- retention plan');
  for (final kept in plan.keep) {
    final tiers = kept.tiers.map((t) => t.name).join(' + ');
    print('  keep  ${_iso(kept.date)}  ($tiers)');
  }
  for (final date in plan.purge) {
    print('  purge ${_iso(date)}');
  }
  for (final date in plan.ignored) {
    print('  leave ${_iso(date)}  (dated ahead of today)');
  }
}

/// 2. A full rotation over a backend you provide.
Future<void> _aFullRotation() async {
  final backend = _InMemoryBackend();

  // Yesterday's generation, plus one nothing will retain.
  await backend.uploadTo('b/daily/demo-2026-07-14.enc', _bytes([1]));
  await backend.uploadTo('b/daily/demo-2026-02-03.enc', _bytes([2]));
  // Something that is not ours: it must survive untouched.
  await backend.uploadTo('b/daily/README.txt', _bytes([3]));

  final service = GfsBackupService(
    filePrefix: 'demo',
    backend: backend,
    snapshotBytes: () async => _bytes([0xDB, 0xDB, 0xDB]),
    // A real app would encrypt here, binding the ciphertext to `isoDate`.
    seal: (plaintext, isoDate) async => plaintext,
    now: () => DateTime.utc(2026, 7, 15),
  );

  final run = await service.backupNow();

  print('\n-- backupNow');
  print('  wrote  ${run.uploadedPath}');
  print('  purged ${run.purged.map(_iso).toList()}');
  print('  left   ${(await backend.listFiles('b/daily')..sort())}');
}

/// 3. The same retention, entirely local: four callbacks, no backend.
Future<void> _aLocalArchive() async {
  final disk = <String, Uint8List>{
    'demo-2026-02-03.sqlite': _bytes([9]), // stale
  };

  final rotator = LocalArchiveRotator(
    filePrefix: 'demo',
    snapshotBytes: () async => _bytes([0xDB, 0xDB, 0xDB]),
    write: (name, bytes) async => disk[name] = bytes,
    list: () async => disk.keys.toList(),
    delete: (name) async => disk.remove(name) != null,
    now: () => DateTime.utc(2026, 7, 15),
  );

  final run = await rotator.archiveNow();

  print('\n-- archiveNow');
  print('  wrote  ${run.writtenFileName}');
  print('  purged ${run.purged}');
  print('  left   ${disk.keys.toList()}');
}

String _iso(DateTime d) => GfsBackupService.isoDate(d);

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// The smallest honest [BackupBackend]: a map keyed by path.
class _InMemoryBackend implements BackupBackend {
  final Map<String, Uint8List> _files = {};

  @override
  Future<void> uploadTo(String relativePath, Uint8List bytes) async =>
      _files[relativePath] = bytes;

  @override
  Future<Uint8List?> downloadFrom(String relativePath) async =>
      _files[relativePath];

  @override
  Future<void> deleteFile(String relativePath) async =>
      _files.remove(relativePath);

  @override
  Future<List<String>> listFiles(String folderPath) async {
    final prefix = '$folderPath/';
    return [
      for (final path in _files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}
