import 'dart:typed_data';

import 'package:gfs_backup/gfs_backup.dart';
import 'package:test/test.dart';

/// In-memory backend that logs its calls, so a test can check what was
/// REALLY deleted — not merely what the plan claimed it would delete.
class _FakeBackend implements BackupBackend {
  final Map<String, Uint8List> uploads = {};
  final List<String> deleteCalls = [];
  final List<String> uploadCalls = [];

  @override
  Future<void> uploadTo(String relativePath, Uint8List bytes) async {
    uploadCalls.add(relativePath);
    uploads[relativePath] = bytes;
  }

  @override
  Future<Uint8List?> downloadFrom(String relativePath) async =>
      uploads[relativePath];

  @override
  Future<void> deleteFile(String relativePath) async {
    deleteCalls.add(relativePath);
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

GfsBackupService _service(
  _FakeBackend backend, {
  required DateTime now,
  String filePrefix = 'app',
  GfsRotationMode mode = GfsRotationMode.flatDaily,
  Future<Uint8List> Function()? snapshot,
  BackupSealer? seal,
}) {
  return GfsBackupService(
    filePrefix: filePrefix,
    snapshotBytes: snapshot ?? () async => Uint8List.fromList([1, 2, 3]),
    backend: backend,
    seal: seal ?? (p, _) async => p,
    mode: mode,
    now: () => now,
  );
}

void main() {
  group('GfsBackupService — first run / empty backend', () {
    test('a completely empty backend: writes, purges nothing', () async {
      final backend = _FakeBackend();
      final result =
          await _service(backend, now: DateTime.utc(2026, 7, 15)).backupNow();

      expect(result.uploadedPath, 'b/daily/app-2026-07-15.enc');
      expect(result.purged, isEmpty);
      expect(backend.deleteCalls, isEmpty);
      expect(result.kept.single.date, DateTime.utc(2026, 7, 15));
    });

    test('a 0-byte snapshot is uploaded all the same (no short-circuit)',
        () async {
      final backend = _FakeBackend();
      final result = await _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        snapshot: () async => Uint8List(0),
      ).backupNow();

      expect(backend.uploads[result.uploadedPath], isEmpty);
      expect(backend.uploadCalls, hasLength(1));
    });

    test('rotateNow alone on an empty backend: empty plan, no delete',
        () async {
      final backend = _FakeBackend();
      final plan =
          await _service(backend, now: DateTime.utc(2026, 7, 15)).rotateNow();
      expect(plan.keep, isEmpty);
      expect(plan.purge, isEmpty);
      expect(backend.deleteCalls, isEmpty);
    });

    test('rotateNow alone writes NO new generation', () async {
      final backend = _FakeBackend();
      backend.uploads['b/daily/app-2026-07-14.enc'] = Uint8List.fromList([1]);
      await _service(backend, now: DateTime.utc(2026, 7, 15)).rotateNow();
      expect(backend.uploadCalls, isEmpty);
      expect(backend.uploads.keys, ['b/daily/app-2026-07-14.enc']);
    });
  });

  group('GfsBackupService — error propagation (nothing partial)', () {
    test('when the sealer refuses (no key), nothing is uploaded', () async {
      // Documented contract: "an implementation that encrypts must throw
      // when no key is configured". Check both that the exception
      // propagates AND that not one byte reached the backend.
      final backend = _FakeBackend();
      final service = _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        seal: (_, __) async => throw StateError('no key configured'),
      );
      await expectLater(service.backupNow(), throwsStateError);
      expect(backend.uploadCalls, isEmpty);
      expect(backend.deleteCalls, isEmpty);
    });

    test('when the snapshot producer fails, the sealer is never called',
        () async {
      final backend = _FakeBackend();
      var sealCalled = false;
      final service = _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        snapshot: () async => throw StateError('database locked'),
        seal: (p, _) async {
          sealCalled = true;
          return p;
        },
      );
      await expectLater(service.backupNow(), throwsStateError);
      expect(sealCalled, isFalse);
      expect(backend.uploadCalls, isEmpty);
    });

    test(
        'the upload happens BEFORE any purge (never purge without a '
        'successful write)', () async {
      // MUTATION CHECK: moving `await _backend.uploadTo(path, envelope)`
      // after the `switch` turns this test red — a delete would precede
      // the upload, purging before the new generation is safe.
      final backend = _FakeBackend();
      backend.uploads['b/daily/app-2026-01-01.enc'] = Uint8List.fromList([9]);
      final order = <String>[];
      final tracking = _TrackingBackend(backend, order);
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: tracking,
        seal: (p, _) async => p,
        now: () => DateTime.utc(2026, 7, 15),
      );
      await service.backupNow();
      expect(order.first, startsWith('upload:'));
      expect(order, contains('delete:b/daily/app-2026-01-01.enc'));
      expect(
        order.indexOf('upload:b/daily/app-2026-07-15.enc') <
            order.indexWhere((e) => e.startsWith('delete:')),
        isTrue,
      );
    });
  });

  group('GfsBackupService — platform-independent backend paths', () {
    test('paths handed to the backend always use "/", Windows included',
        () async {
      // The same code runs on Android, Windows, macOS and Linux: a remote
      // path must NEVER pick up a Windows separator, or a device stops
      // finding the very generations it wrote itself.
      final backend = _FakeBackend();
      final result =
          await _service(backend, now: DateTime.utc(2026, 7, 15)).backupNow();
      expect(result.uploadedPath, contains('/'));
      expect(result.uploadedPath, isNot(contains(r'\')));
      for (final call in backend.uploadCalls) {
        expect(call, isNot(contains(r'\')));
      }
    });

    test('custom folders are honoured on write and on purge', () async {
      final backend = _FakeBackend();
      backend.uploads['backups/daily/archive-2026-01-01.enc'] =
          Uint8List.fromList([9]);
      final service = GfsBackupService(
        filePrefix: 'archive',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        dailyFolder: 'backups/daily',
        now: () => DateTime.utc(2026, 7, 15),
      );
      final result = await service.backupNow();
      expect(result.uploadedPath, 'backups/daily/archive-2026-07-15.enc');
      expect(
        backend.deleteCalls,
        contains('backups/daily/archive-2026-01-01.enc'),
      );
    });

    test('a prefix containing a hyphen stays unambiguously parsable', () async {
      final backend = _FakeBackend();
      final service = _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        filePrefix: 'my-app',
      );
      expect(
        service.parseDateFromFileName('my-app-2026-07-11.enc'),
        DateTime.utc(2026, 7, 11),
      );
      final result = await service.backupNow();
      expect(result.uploadedPath, 'b/daily/my-app-2026-07-15.enc');
    });

    test('a non-ASCII prefix round-trips cleanly', () async {
      final backend = _FakeBackend();
      final service = _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        filePrefix: 'café',
      );
      final result = await service.backupNow();
      expect(result.uploadedPath, 'b/daily/café-2026-07-15.enc');
      expect(
        service.parseDateFromFileName('café-2026-07-15.enc'),
        DateTime.utc(2026, 7, 15),
      );
    });
  });

  group('GfsBackupService.parseDateFromFileName — foreign names', () {
    final service = _service(_FakeBackend(), now: DateTime.utc(2026, 7, 15));

    test('rejects foreign prefixes, extensions and shapes', () {
      expect(service.parseDateFromFileName('other-2026-07-11.enc'), isNull);
      expect(service.parseDateFromFileName('app-2026-07-11.sqlite'), isNull);
      expect(service.parseDateFromFileName('app-2026-07.enc'), isNull);
      expect(service.parseDateFromFileName('app-2026-07-11-12.enc'), isNull);
      expect(service.parseDateFromFileName('app-aaaa-bb-cc.enc'), isNull);
      expect(service.parseDateFromFileName('manifest.json'), isNull);
      expect(service.parseDateFromFileName(''), isNull);
      expect(service.parseDateFromFileName('app-.enc'), isNull);
    });

    test('a foreign file is neither counted nor deleted', () async {
      final backend = _FakeBackend();
      backend.uploads['b/daily/README.txt'] = Uint8List.fromList([1]);
      backend.uploads['b/daily/other-2026-01-01.enc'] = Uint8List.fromList([2]);
      await _service(backend, now: DateTime.utc(2026, 7, 15)).backupNow();
      expect(backend.deleteCalls, isEmpty);
      expect(backend.uploads.keys, contains('b/daily/README.txt'));
      expect(backend.uploads.keys, contains('b/daily/other-2026-01-01.enc'));
    });
  });

  group(
      'GfsBackupService — known edge: lenient parser vs '
      'LocalArchiveRotator', () {
    test(
        'DEFECT: a non-zero-padded date is accepted, then "purged" under '
        'a different name (the real file survives, the report lies)', () async {
      // `GfsBackupService.parseDateFromFileName` does NOT check field
      // widths, unlike `LocalArchiveRotator`, which demands 4-2-2. So
      // `app-26-7-1.enc` parses as year 26 → outside every window → the
      // purge rebuilds the name through `isoDate`, which zero-pads month
      // and day: `app-26-07-01.enc`. That file does not exist. Net
      // result: the real file is NEVER deleted (a silent leak) and
      // `result.purged` reports a deletion that never happened.
      //
      // Characterization test: it locks the CURRENT behaviour and stands
      // as the proof for the fix (aligning the two parsers).
      final backend = _FakeBackend();
      backend.uploads['b/daily/app-26-7-1.enc'] = Uint8List.fromList([9]);

      final result =
          await _service(backend, now: DateTime.utc(2026, 7, 15)).backupNow();

      expect(result.purged, contains(DateTime.utc(26, 7, 1)));
      // The delete targeted a zero-padded name — a different file.
      expect(backend.deleteCalls, contains('b/daily/app-26-07-01.enc'));
      // ... and the real file is still there.
      expect(backend.uploads.keys, contains('b/daily/app-26-7-1.enc'));
    });

    test(
        'DEFECT: an out-of-range month/day is "normalized" into a real '
        'date instead of being rejected', () async {
      // `DateTime.utc(2026, 13, 45)` does not throw: it overflows into
      // 2027-02-14, so a corrupted name becomes a plausible date.
      final service = _service(_FakeBackend(), now: DateTime.utc(2026, 7, 15));
      expect(
        service.parseDateFromFileName('app-2026-13-45.enc'),
        DateTime.utc(2027, 2, 14),
      );
      // For comparison the local rotator overflows the same way — but it
      // does at least reject the field widths.
      expect(
        service.parseDateFromFileName('app-2026-7-15.enc'),
        isNotNull,
        reason: 'field width unchecked on the GfsBackupService side',
      );
    });

    test('LocalArchiveRotator REJECTS those same names (the asymmetry)', () {
      final rotator = LocalArchiveRotator(
        filePrefix: 'app',
        fileSuffix: '.enc',
        snapshotBytes: () async => Uint8List(0),
        write: (_, __) async {},
        list: () async => const [],
        delete: (_) async => true,
      );
      expect(rotator.parseDateFromFileName('app-26-7-1.enc'), isNull);
      expect(rotator.parseDateFromFileName('app-2026-7-15.enc'), isNull);
    });
  });

  group('GfsBackupService — tieredFolders mode, edge cases', () {
    test('empty folders: no purge, no stray call', () async {
      final backend = _FakeBackend();
      final result = await _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        mode: GfsRotationMode.tieredFolders,
        filePrefix: 'app',
      ).backupNow();
      expect(result.purged, isEmpty);
      expect(backend.deleteCalls, isEmpty);
      expect(result.kept.single.date, DateTime.utc(2026, 7, 15));
    });

    test('exactly `dailyRetention` generations: no purge (the boundary)',
        () async {
      // MUTATION CHECK: `if (names.length <= retain) return const []` →
      // `< retain` would delete one generation too many here → red.
      final backend = _FakeBackend();
      for (var d = 9; d <= 14; d++) {
        backend.uploads['b/daily/app-2026-07-$d.enc'] = Uint8List.fromList([d]);
      }
      // 6 existing + today's = 7 = dailyRetention.
      final result = await _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        mode: GfsRotationMode.tieredFolders,
        filePrefix: 'app',
      ).backupNow();
      expect(result.purged, isEmpty);
      expect(backend.deleteCalls, isEmpty);
      expect(await backend.listFiles('b/daily'), hasLength(7));
    });

    test('one too many: exactly one purge, the oldest', () async {
      final backend = _FakeBackend();
      for (var d = 8; d <= 14; d++) {
        final dd = d.toString().padLeft(2, '0');
        backend.uploads['b/daily/app-2026-07-$dd.enc'] =
            Uint8List.fromList([d]);
      }
      final result = await _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        mode: GfsRotationMode.tieredFolders,
        filePrefix: 'app',
      ).backupNow();
      expect(result.purged, [DateTime.utc(2026, 7, 8)]);
      expect(backend.deleteCalls, ['b/daily/app-2026-07-08.enc']);
    });

    test('the promoted copy is byte-for-byte the daily one (same envelope)',
        () async {
      final backend = _FakeBackend();
      await _service(
        backend,
        now: DateTime.utc(2026, 3, 1), // a Sunday AND the 1st
        mode: GfsRotationMode.tieredFolders,
        filePrefix: 'app',
        snapshot: () async => Uint8List.fromList([7, 7, 7]),
        seal: (p, _) async => Uint8List.fromList([...p, 0xAA]),
      ).backupNow();

      final daily = backend.uploads['b/daily/app-2026-03-01.enc'];
      expect(backend.uploads['b/weekly/app-2026-03-01.enc'], daily);
      expect(backend.uploads['b/monthly/app-2026-03-01.enc'], daily);
      // The snapshot was produced and sealed exactly once.
      expect(daily, [7, 7, 7, 0xAA]);
    });

    test('custom retention counts are honoured per folder', () async {
      final backend = _FakeBackend();
      for (var d = 1; d <= 5; d++) {
        backend.uploads['b/daily/app-2026-07-0$d.enc'] =
            Uint8List.fromList([d]);
      }
      final service = GfsBackupService(
        filePrefix: 'app',
        snapshotBytes: () async => Uint8List.fromList([1]),
        backend: backend,
        seal: (p, _) async => p,
        mode: GfsRotationMode.tieredFolders,
        dailyRetention: 2,
        now: () => DateTime.utc(2026, 7, 15),
      );
      await service.backupNow();
      expect(await backend.listFiles('b/daily'), hasLength(2));
      expect(
        await backend.listFiles('b/daily'),
        contains('app-2026-07-15.enc'),
      );
    });

    test('in tiered mode, `kept` describes ONLY the daily folder', () async {
      final backend = _FakeBackend();
      backend.uploads['b/monthly/app-2026-01-01.enc'] = Uint8List.fromList([1]);
      final result = await _service(
        backend,
        now: DateTime.utc(2026, 7, 15),
        mode: GfsRotationMode.tieredFolders,
        filePrefix: 'app',
      ).backupNow();
      expect(
        result.kept.map((k) => k.date),
        isNot(contains(DateTime.utc(2026, 1, 1))),
      );
      expect(
        result.kept.every((k) => k.tiers.contains(BackupTier.daily)),
        isTrue,
      );
    });
  });

  group('GfsBackupService — idempotence', () {
    test('two runs on the same day: one generation, no stray purge', () async {
      final backend = _FakeBackend();
      final service = _service(backend, now: DateTime.utc(2026, 7, 15));
      await service.backupNow();
      final second = await service.backupNow();
      expect(await backend.listFiles('b/daily'), hasLength(1));
      expect(second.purged, isEmpty);
      expect(backend.deleteCalls, isEmpty);
    });
  });
}

/// Decorator that records the ORDER of the backend operations.
class _TrackingBackend implements BackupBackend {
  _TrackingBackend(this._inner, this._log);

  final BackupBackend _inner;
  final List<String> _log;

  @override
  Future<void> uploadTo(String relativePath, Uint8List bytes) {
    _log.add('upload:$relativePath');
    return _inner.uploadTo(relativePath, bytes);
  }

  @override
  Future<Uint8List?> downloadFrom(String relativePath) =>
      _inner.downloadFrom(relativePath);

  @override
  Future<void> deleteFile(String relativePath) {
    _log.add('delete:$relativePath');
    return _inner.deleteFile(relativePath);
  }

  @override
  Future<List<String>> listFiles(String folderPath) =>
      _inner.listFiles(folderPath);
}
