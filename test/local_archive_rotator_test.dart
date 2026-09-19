import 'dart:typed_data';

import 'package:gfs_backup/gfs_backup.dart';
import 'package:test/test.dart';

/// In-memory sink standing in for a Storage Access Framework folder on
/// Android or a real `Directory` on desktop — the rotator never touches a
/// filesystem itself, which is exactly what makes this test possible.
class _FakeSink {
  final Map<String, Uint8List> files = {};

  /// Names [delete] should report as failed — removed from the map like
  /// any other delete (so a re-run does not see them as stale twice) but
  /// reported `false`, exactly like a native delete that swallowed its own
  /// exception.
  final Set<String> failingDeletes = {};

  Future<void> write(String name, Uint8List bytes) async {
    files[name] = bytes;
  }

  Future<List<String>> list() async => files.keys.toList();

  Future<bool> delete(String name) async {
    final existed = files.remove(name) != null;
    return existed && !failingDeletes.contains(name);
  }
}

LocalArchiveRotator _make(
  _FakeSink sink, {
  required DateTime Function() now,
  Future<Uint8List> Function()? snapshot,
  String filePrefix = 'app',
}) {
  return LocalArchiveRotator(
    filePrefix: filePrefix,
    snapshotBytes: snapshot ?? () async => Uint8List.fromList([1, 2, 3]),
    write: sink.write,
    list: sink.list,
    delete: sink.delete,
    now: now,
  );
}

void main() {
  group('LocalArchiveRotator.archiveNow', () {
    test("writes today's generation with the canonical name", () async {
      final sink = _FakeSink();
      final rotator = _make(sink, now: () => DateTime.utc(2026, 7, 11));

      final result = await rotator.archiveNow();

      expect(result.writtenFileName, 'app-2026-07-11.sqlite');
      expect(sink.files.keys, contains('app-2026-07-11.sqlite'));
      expect(sink.files['app-2026-07-11.sqlite'], [1, 2, 3]);
    });

    test('same-day re-run overwrites, never duplicates', () async {
      final sink = _FakeSink();
      var payload = <int>[1];
      final rotator = _make(
        sink,
        now: () => DateTime.utc(2026, 7, 11),
        snapshot: () async => Uint8List.fromList(payload),
      );

      await rotator.archiveNow();
      payload = [2];
      final second = await rotator.archiveNow();

      expect(sink.files, hasLength(1));
      expect(sink.files[second.writtenFileName], [2]);
      expect(second.purged, isEmpty);
    });

    test('applies the GFS plan: a stale non-tier date is purged', () async {
      final sink = _FakeSink();
      // 40 days back from a Wednesday: outside daily/weekly/monthly windows
      // (2026-06-05 is a Friday, not a 1st).
      sink.files['app-2026-06-05.sqlite'] = Uint8List.fromList([9]);

      final rotator = _make(sink, now: () => DateTime.utc(2026, 7, 15));
      final result = await rotator.archiveNow();

      expect(result.purged, ['app-2026-06-05.sqlite']);
      expect(sink.files.keys, isNot(contains('app-2026-06-05.sqlite')));
      expect(sink.files.keys, contains('app-2026-07-15.sqlite'));
    });

    test('keeps 7 daily generations across a simulated week+', () async {
      final sink = _FakeSink();
      var day = DateTime.utc(2026, 7, 1);
      final rotator = _make(sink, now: () => day);

      // Run once a day for 20 consecutive days.
      for (var i = 0; i < 20; i++) {
        day = DateTime.utc(2026, 7, 1 + i);
        await rotator.archiveNow();
      }

      // Present afterwards: the 7 most recent dailies (2026-07-14..20),
      // the Sundays of the last 4 ISO weeks that had a run (07-05, 07-12,
      // 07-19 — 07-19 is also a daily), and the 1st of the month (07-01).
      final names = sink.files.keys.toSet();
      for (var d = 14; d <= 20; d++) {
        expect(names, contains('app-2026-07-$d.sqlite'));
      }
      expect(names, contains('app-2026-07-05.sqlite')); // Sunday
      expect(names, contains('app-2026-07-12.sqlite')); // Sunday
      expect(names, contains('app-2026-07-01.sqlite')); // 1st of month
      // Plain weekdays outside the daily window are gone.
      expect(names, isNot(contains('app-2026-07-02.sqlite')));
      expect(names, isNot(contains('app-2026-07-08.sqlite')));
      expect(names.length, 10);
    });

    // `purged` used to list every generation the plan wanted gone, whether
    // or not the delete actually succeeded — a sink that swallows its own
    // exception and returns `false` was counted as a successful purge, just
    // like a real deletion.
    test('a delete that returns false is not counted as purged', () async {
      final sink = _FakeSink();
      sink.files['app-2026-06-05.sqlite'] = Uint8List.fromList([9]);
      sink.failingDeletes.add('app-2026-06-05.sqlite');

      final rotator = _make(sink, now: () => DateTime.utc(2026, 7, 15));
      final result = await rotator.archiveNow();

      expect(result.purged, isEmpty);
    });

    test('foreign file names in the sink are never touched', () async {
      final sink = _FakeSink();
      sink.files['notes.txt'] = Uint8List.fromList([1]);
      sink.files['m-2026-06-01.sqlite'] = Uint8List.fromList([2]); // other app
      sink.files['app-2026.sqlite'] = Uint8List.fromList([3]); // malformed
      sink.files['app-2026-06-05.sqlite'] = Uint8List.fromList([4]); // stale

      final rotator = _make(sink, now: () => DateTime.utc(2026, 7, 15));
      final result = await rotator.archiveNow();

      expect(sink.files.keys, contains('notes.txt'));
      expect(sink.files.keys, contains('m-2026-06-01.sqlite'));
      expect(sink.files.keys, contains('app-2026.sqlite'));
      // Only this rotator's own stale generation was purged.
      expect(result.purged, ['app-2026-06-05.sqlite']);
    });

    test('works with zero cloud configuration — pure callbacks', () async {
      // The whole point of the primitive: nothing here ever constructed a
      // backend, a cloud client or a passphrase. This test doubles as the
      // API contract lock.
      final sink = _FakeSink();
      final rotator = LocalArchiveRotator(
        filePrefix: 'archive',
        fileSuffix: '.db',
        snapshotBytes: () async => Uint8List.fromList([42]),
        write: sink.write,
        list: sink.list,
        delete: sink.delete,
        now: () => DateTime.utc(2026, 7, 11),
      );

      final result = await rotator.archiveNow();
      expect(result.writtenFileName, 'archive-2026-07-11.db');
      expect(
        result.kept.map((k) => k.date),
        contains(DateTime.utc(2026, 7, 11)),
      );
    });
  });

  group('LocalArchiveRotator.parseDateFromFileName', () {
    final rotator = _make(_FakeSink(), now: DateTime.now);

    test('parses a canonical name', () {
      expect(
        rotator.parseDateFromFileName('app-2026-07-11.sqlite'),
        DateTime.utc(2026, 7, 11),
      );
    });

    test('rejects other prefixes, suffixes and malformed dates', () {
      expect(rotator.parseDateFromFileName('m-2026-07-11.sqlite'), isNull);
      expect(rotator.parseDateFromFileName('app-2026-07-11.enc'), isNull);
      expect(rotator.parseDateFromFileName('app-26-7-1.sqlite'), isNull);
      expect(rotator.parseDateFromFileName('app-abcd-ef-gh.sqlite'), isNull);
    });
  });
}
