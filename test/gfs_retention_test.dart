import 'package:gfs_backup/gfs_backup.dart';
import 'package:test/test.dart';

// Ported from D's `test/core/backup/gfs_retention_test.dart` — the moved
// logic must classify exactly as it did in-app (règle d'or: par défaut
// rien ne bouge).
void main() {
  group('GfsRetentionPlan.compute', () {
    test('keeps the 7 most recent daily dates present', () {
      final now = DateTime.utc(2026, 7, 15); // Wednesday
      final present = [
        for (var i = 0; i < 10; i++) now.subtract(Duration(days: i)),
      ];
      final plan = GfsRetentionPlan.compute(now: now, presentDates: present);

      final keptDates = plan.keep.map((r) => r.date).toSet();
      for (var i = 0; i < 7; i++) {
        expect(keptDates, contains(now.subtract(Duration(days: i))));
      }
      expect(plan.purge, isNotEmpty);
    });

    test('purges a daily date once it falls outside every tier window', () {
      final now = DateTime.utc(2026, 7, 15);
      final stale = now.subtract(const Duration(days: 40));
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [now, stale],
      );
      expect(plan.purge, contains(stale));
      expect(plan.keep.map((r) => r.date), isNot(contains(stale)));
    });

    test('promotes the Sunday of the current week to weekly', () {
      // 2026-07-12 is a Sunday.
      final sunday = DateTime.utc(2026, 7, 12);
      final now = DateTime.utc(2026, 7, 15); // Wednesday, same week
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [sunday],
      );
      final entry = plan.keep.singleWhere((r) => r.date == sunday);
      expect(entry.tiers, contains(BackupTier.weekly));
    });

    test('keeps the Sunday from 3 weeks ago (4th weekly generation)', () {
      final now = DateTime.utc(2026, 7, 15); // Wednesday
      final sunday3WeeksAgo = DateTime.utc(2026, 6, 21); // Sunday
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [sunday3WeeksAgo],
      );
      final entry = plan.keep.singleWhere((r) => r.date == sunday3WeeksAgo);
      expect(entry.tiers, contains(BackupTier.weekly));
    });

    test('a Sunday older than 4 weeks is not retained as weekly', () {
      final now = DateTime.utc(2026, 7, 15); // Wednesday
      final oldSunday = DateTime.utc(2026, 6, 14); // Sunday, 4+ weeks back
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [oldSunday],
      );
      expect(
        plan.keep.where(
          (r) => r.date == oldSunday && r.tiers.contains(BackupTier.weekly),
        ),
        isEmpty,
      );
    });

    test('promotes the 1st of each of the last 6 months to monthly', () {
      final now = DateTime.utc(2026, 7, 15);
      final firsts = [
        for (var i = 0; i < 6; i++) DateTime.utc(2026, 7 - i, 1),
      ];
      final plan = GfsRetentionPlan.compute(now: now, presentDates: firsts);
      for (final first in firsts) {
        final entry = plan.keep.singleWhere((r) => r.date == first);
        expect(entry.tiers, contains(BackupTier.monthly));
      }
    });

    test('monthly window wraps across a year boundary', () {
      final now = DateTime.utc(2026, 2, 10);
      final decemberFirst = DateTime.utc(2025, 12, 1);
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [decemberFirst],
      );
      final entry = plan.keep.singleWhere((r) => r.date == decemberFirst);
      expect(entry.tiers, contains(BackupTier.monthly));
    });

    test('a date can satisfy several tiers at once (kept once)', () {
      // 2026-03-01 is a Sunday AND a 1st of month.
      final date = DateTime.utc(2026, 3, 1);
      expect(date.weekday, DateTime.sunday);
      final now = DateTime.utc(2026, 3, 4);
      final plan = GfsRetentionPlan.compute(now: now, presentDates: [date]);
      final entries = plan.keep.where((r) => r.date == date).toList();
      expect(entries, hasLength(1));
      expect(entries.single.tiers, contains(BackupTier.daily));
      expect(entries.single.tiers, contains(BackupTier.weekly));
      expect(entries.single.tiers, contains(BackupTier.monthly));
    });

    test('time-of-day and non-UTC inputs are normalized to calendar dates', () {
      final now = DateTime(2026, 7, 15, 23, 45); // local, with time
      final presentLocal = DateTime(2026, 7, 15, 3, 2, 1);
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [presentLocal],
      );
      expect(plan.keep.single.date, DateTime.utc(2026, 7, 15));
    });
  });
}
