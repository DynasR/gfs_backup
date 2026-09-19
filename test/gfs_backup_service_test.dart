import 'dart:typed_data';

import 'package:gfs_backup/gfs_backup.dart';
import 'package:test/test.dart';

/// In-memory [BackupBackend]: the whole point of the four-method surface
/// is that a faithful fake fits in thirty lines.
class _FakeBackend implements BackupBackend {
  final Map<String, Uint8List> uploads = {};

  @override
  Future<void> uploadTo(String relativePath, Uint8List bytes) async {
    uploads[relativePath] = bytes;
  }

  @override
  Future<Uint8List?> downloadFrom(String relativePath) async =>
      uploads[relativePath];

  @override
  Future<void> deleteFile(String relativePath) async {
    uploads.remove(relativePath);
  }

  @override
  Future<List<String>> listFiles(String folderPath) async {
    final prefix = folderPath.isEmpty ? '' : '$folderPath/';
    final names = <String>{};
    for (final path in uploads.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      names.add(slash == -1 ? rest : rest.substring(0, slash));
    }
    return names.toList();
  }
}

void main() {
  group('GfsBackupService — flatDaily', () {
    test('writes the sealed daily blob at b/daily/<prefix>-<date>.enc',
        () async {
      final backend = _FakeBackend();
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
        backend: backend,
        seal: (plaintext, isoDate) async =>
            Uint8List.fromList([...plaintext, 0xFF]),
        now: () => DateTime.utc(2026, 7, 11, 14, 30),
      );

      final result = await service.backupNow();

      expect(result.uploadedPath, 'b/daily/app-2026-07-11.enc');
      expect(backend.uploads['b/daily/app-2026-07-11.enc'], [1, 2, 3, 0xFF]);
      expect(result.promotedPaths, isEmpty);
    });

    test('sealer receives the generation ISO date (AAD building)', () async {
      final backend = _FakeBackend();
      String? seenIso;
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (plaintext, isoDate) async {
          seenIso = isoDate;
          return plaintext;
        },
        now: () => DateTime.utc(2026, 7, 11),
      );

      await service.backupNow();
      expect(seenIso, '2026-07-11');
    });

    test('rotation purges dates no tier retains, keeps the plan', () async {
      final backend = _FakeBackend();
      // A stale blob 40 days back (no tier) + a Sunday 2 weeks back.
      backend.uploads['b/daily/app-2026-06-05.enc'] = Uint8List.fromList([9]);
      backend.uploads['b/daily/app-2026-07-05.enc'] =
          Uint8List.fromList([8]); // Sunday
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        now: () => DateTime.utc(2026, 7, 15),
      );

      final result = await service.backupNow();

      expect(result.purged, [DateTime.utc(2026, 6, 5)]);
      expect(
        backend.uploads.keys,
        isNot(contains('b/daily/app-2026-06-05.enc')),
      );
      expect(backend.uploads.keys, contains('b/daily/app-2026-07-05.enc'));
      final keptDates = result.kept.map((k) => k.date).toSet();
      expect(keptDates, contains(DateTime.utc(2026, 7, 15)));
      expect(keptDates, contains(DateTime.utc(2026, 7, 5)));
    });

    test('foreign file names in b/daily are ignored, never purged', () async {
      final backend = _FakeBackend();
      backend.uploads['b/daily/m-2026-06-05.enc'] = Uint8List.fromList([7]);
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        now: () => DateTime.utc(2026, 7, 15),
      );

      await service.backupNow();
      expect(backend.uploads.keys, contains('b/daily/m-2026-06-05.enc'));
    });
  });

  group('GfsBackupService — tieredFolders', () {
    test('promotes a Sunday to b/weekly and a 1st to b/monthly', () async {
      final backend = _FakeBackend();
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        mode: GfsRotationMode.tieredFolders,
        // 2026-03-01 is both a Sunday and a 1st of month.
        now: () => DateTime.utc(2026, 3, 1),
      );

      final result = await service.backupNow();

      expect(result.uploadedPath, 'b/daily/app-2026-03-01.enc');
      expect(result.promotedPaths, [
        'b/weekly/app-2026-03-01.enc',
        'b/monthly/app-2026-03-01.enc',
      ]);
      expect(backend.uploads.keys, contains('b/weekly/app-2026-03-01.enc'));
      expect(backend.uploads.keys, contains('b/monthly/app-2026-03-01.enc'));
    });

    test('a plain weekday is not promoted', () async {
      final backend = _FakeBackend();
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        mode: GfsRotationMode.tieredFolders,
        now: () => DateTime.utc(2026, 7, 15), // Wednesday, not a 1st
      );

      final result = await service.backupNow();
      expect(result.promotedPaths, isEmpty);
      expect(backend.uploads.keys, ['b/daily/app-2026-07-15.enc']);
    });

    test('each tier folder is pruned to its own retention count', () async {
      final backend = _FakeBackend();
      // 9 dailies (retain 7), 5 weeklies (retain 4), 7 monthlies (retain 6).
      for (var d = 1; d <= 9; d++) {
        backend.uploads['b/daily/app-2026-07-0$d.enc'] =
            Uint8List.fromList([d]);
      }
      for (var w = 1; w <= 5; w++) {
        backend.uploads['b/weekly/app-2026-0$w-04.enc'] =
            Uint8List.fromList([w]);
      }
      for (var m = 1; m <= 7; m++) {
        backend.uploads['b/monthly/app-2026-0$m-01.enc'] =
            Uint8List.fromList([m]);
      }
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        mode: GfsRotationMode.tieredFolders,
        now: () => DateTime.utc(2026, 7, 10), // Friday, not a 1st
      );

      await service.backupNow();

      // Daily: 9 pre-existing + today's = 10 → oldest 3 purged.
      final daily = await backend.listFiles('b/daily');
      expect(daily, hasLength(7));
      expect(daily, isNot(contains('app-2026-07-01.enc')));
      expect(daily, isNot(contains('app-2026-07-02.enc')));
      expect(daily, isNot(contains('app-2026-07-03.enc')));
      expect(daily, contains('app-2026-07-10.enc'));

      final weekly = await backend.listFiles('b/weekly');
      expect(weekly, hasLength(4));
      expect(weekly, isNot(contains('app-2026-01-04.enc')));

      final monthly = await backend.listFiles('b/monthly');
      expect(monthly, hasLength(6));
      expect(monthly, isNot(contains('app-2026-01-01.enc')));
    });
  });
}
