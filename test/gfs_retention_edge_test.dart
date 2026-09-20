import 'package:gfs_backup/gfs_backup.dart';
import 'package:test/test.dart';

/// Retention boundaries — the companion to `gfs_retention_test.dart`.
///
/// What is at stake: this is the ONLY logic that decides which backups get
/// DELETED. An off-by-one day here erases a generation its owner believed
/// was kept. So every boundary of the three tiers is locked from both
/// sides: the last day retained AND the first day purged.
void main() {
  group('GFS — degenerate inputs', () {
    test('no generation at all: nothing to keep, nothing to purge', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15),
        presentDates: const [],
      );
      expect(plan.keep, isEmpty);
      expect(plan.purge, isEmpty);
    });

    test('a single generation dated today: kept, never purged', () {
      final today = DateTime.utc(2026, 7, 15);
      final plan = GfsRetentionPlan.compute(now: today, presentDates: [today]);
      expect(plan.purge, isEmpty);
      expect(plan.keep.single.date, today);
      expect(plan.keep.single.tiers, contains(BackupTier.daily));
    });

    test('a single very old generation: purged (no tier saves it)', () {
      // The only file in the world, but outside all three windows →
      // deleted. Intended behaviour for a rotation, locked explicitly
      // because this is the case where someone loses their last backup by
      // never taking a new one.
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15),
        presentDates: [DateTime.utc(2024, 3, 14)],
      );
      expect(plan.keep, isEmpty);
      expect(plan.purge, [DateTime.utc(2024, 3, 14)]);
    });

    test('strictly identical dates: deduplicated, kept once', () {
      final today = DateTime.utc(2026, 7, 15);
      final plan = GfsRetentionPlan.compute(
        now: today,
        presentDates: [today, today, today],
      );
      expect(plan.keep, hasLength(1));
      expect(plan.purge, isEmpty);
    });

    test('the same day at different times: one calendar date', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15, 12),
        presentDates: [
          DateTime.utc(2026, 7, 15, 0, 0, 0),
          DateTime.utc(2026, 7, 15, 23, 59, 59),
          DateTime.utc(2026, 7, 15, 12, 30),
        ],
      );
      expect(plan.keep, hasLength(1));
      expect(plan.keep.single.date, DateTime.utc(2026, 7, 15));
      expect(plan.purge, isEmpty);
    });

    test('unsorted input: the result is sorted newest to oldest', () {
      final now = DateTime.utc(2026, 7, 15);
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [
          DateTime.utc(2026, 7, 13),
          DateTime.utc(2026, 7, 15),
          DateTime.utc(2026, 7, 14),
        ],
      );
      expect(
        plan.keep.map((k) => k.date).toList(),
        [
          DateTime.utc(2026, 7, 15),
          DateTime.utc(2026, 7, 14),
          DateTime.utc(2026, 7, 13),
        ],
      );
    });

    test('purges are sorted newest to oldest as well', () {
      final now = DateTime.utc(2026, 7, 15);
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [
          DateTime.utc(2025, 1, 3),
          DateTime.utc(2025, 6, 9),
          DateTime.utc(2025, 3, 4),
        ],
      );
      expect(plan.purge, [
        DateTime.utc(2025, 6, 9),
        DateTime.utc(2025, 3, 4),
        DateTime.utc(2025, 1, 3),
      ]);
    });
  });

  group('GFS — boundary of the "7 daily" tier', () {
    // 2026-07-15 is a Wednesday. D-6 = 2026-07-09 (Thursday), D-7 =
    // 2026-07-08 (Wednesday): neither is a Sunday nor a 1st, so only the
    // daily tier can save them — the boundary is cleanly isolated.
    final now = DateTime.utc(2026, 7, 15);

    test('D-6 is the oldest daily retained', () {
      final d = DateTime.utc(2026, 7, 9);
      final plan = GfsRetentionPlan.compute(now: now, presentDates: [d]);
      expect(plan.keep.single.tiers, {BackupTier.daily});
      expect(plan.purge, isEmpty);
    });

    test('D-7 falls out of the daily tier and is purged', () {
      // MUTATION CHECK: widening the daily loop from `i < 7` to `i < 8`
      // turns this red — D-7 would be retained instead of purged.
      final d = DateTime.utc(2026, 7, 8);
      final plan = GfsRetentionPlan.compute(now: now, presentDates: [d]);
      expect(plan.keep, isEmpty);
      expect(plan.purge, [d]);
    });

    test('the 7 consecutive days D-0..D-6 are all retained', () {
      final present = [
        for (var i = 0; i < 7; i++) now.subtract(Duration(days: i)),
      ];
      final plan = GfsRetentionPlan.compute(now: now, presentDates: present);
      expect(plan.keep, hasLength(7));
      expect(plan.purge, isEmpty);
    });
  });

  group('GFS — boundary of the "4 weekly" tier', () {
    final now = DateTime.utc(2026, 7, 15); // a Wednesday

    test('the current week\'s Sunday counts as the 1st week', () {
      final sunday = DateTime.utc(2026, 7, 12);
      expect(sunday.weekday, DateTime.sunday);
      final plan = GfsRetentionPlan.compute(now: now, presentDates: [sunday]);
      expect(plan.keep.single.tiers, contains(BackupTier.weekly));
    });

    test('the 4th Sunday back is retained, the 5th is purged', () {
      // MUTATION CHECK: `i < 4` → `i < 3` would purge the 4th Sunday.
      final sunday4 = DateTime.utc(2026, 6, 21); // 3 weeks back
      final sunday5 = DateTime.utc(2026, 6, 14); // 4 weeks back
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [sunday4, sunday5],
      );
      expect(
        plan.keep.map((k) => k.date),
        contains(sunday4),
      );
      expect(plan.purge, contains(sunday5));
    });

    test('when today IS a Sunday, it is its own representative', () {
      final sunday = DateTime.utc(2026, 7, 12);
      expect(sunday.weekday, DateTime.sunday);
      final plan =
          GfsRetentionPlan.compute(now: sunday, presentDates: [sunday]);
      expect(
        plan.keep.single.tiers,
        containsAll([BackupTier.daily, BackupTier.weekly]),
      );
    });

    test('on a Monday, the week\'s Sunday is yesterday, not in 6 days', () {
      // weekday % 7: Monday(1) → 1 day back. Were the arithmetic off by a
      // day, the week's Sunday would stop being retained.
      final monday = DateTime.utc(2026, 7, 13);
      expect(monday.weekday, DateTime.monday);
      final sunday = DateTime.utc(2026, 7, 12);
      final plan =
          GfsRetentionPlan.compute(now: monday, presentDates: [sunday]);
      expect(plan.keep.single.date, sunday);
      expect(plan.keep.single.tiers, contains(BackupTier.weekly));
    });

    test('on a Saturday, the week\'s Sunday is the one 6 days back', () {
      final saturday = DateTime.utc(2026, 7, 18);
      expect(saturday.weekday, DateTime.saturday);
      final sunday = DateTime.utc(2026, 7, 12);
      final plan =
          GfsRetentionPlan.compute(now: saturday, presentDates: [sunday]);
      expect(plan.keep.single.tiers, contains(BackupTier.weekly));
    });

    test('a Saturday or a Tuesday is never promoted to weekly', () {
      final now = DateTime.utc(2026, 7, 15);
      for (final d in [DateTime.utc(2026, 7, 11), DateTime.utc(2026, 7, 14)]) {
        final plan = GfsRetentionPlan.compute(now: now, presentDates: [d]);
        expect(
          plan.keep.single.tiers,
          isNot(contains(BackupTier.weekly)),
          reason: '$d',
        );
      }
    });
  });

  group('GFS — boundary of the "6 monthly" tier', () {
    final now = DateTime.utc(2026, 7, 15);

    test('the 1st of the 6th month back is retained, the 7th is purged', () {
      // MUTATION CHECK: `i < 6` → `i < 5` would purge the 1st of February.
      final february = DateTime.utc(2026, 2, 1); // i = 5, last retained
      final january = DateTime.utc(2026, 1, 1); // i = 6, outside the window
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [february, january],
      );
      expect(plan.keep.map((k) => k.date), contains(february));
      expect(plan.purge, contains(january));
    });

    test('only the 1st of the month is promoted — not the 2nd nor the 31st',
        () {
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [DateTime.utc(2026, 4, 2), DateTime.utc(2026, 3, 31)],
      );
      expect(plan.keep, isEmpty);
      expect(plan.purge, hasLength(2));
    });

    test('the monthly window crosses a year boundary', () {
      final now = DateTime.utc(2026, 1, 20);
      // i=0..5 → 2026-01, 2025-12, 2025-11, 2025-10, 2025-09, 2025-08.
      final inside = DateTime.utc(2025, 8, 1);
      final outside = DateTime.utc(2025, 7, 1);
      final plan = GfsRetentionPlan.compute(
        now: now,
        presentDates: [inside, outside],
      );
      expect(plan.keep.map((k) => k.date), contains(inside));
      expect(plan.purge, contains(outside));
    });

    test('29 February of a leap year is treated as an ordinary day', () {
      final now = DateTime.utc(2028, 3, 2);
      final leap = DateTime.utc(2028, 2, 29);
      final plan = GfsRetentionPlan.compute(now: now, presentDates: [leap]);
      expect(plan.keep.single.date, leap);
      expect(plan.keep.single.tiers, contains(BackupTier.daily));
    });

    test('1 March still retains 1 February in a leap year', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2028, 3, 1),
        presentDates: [DateTime.utc(2028, 2, 1)],
      );
      expect(plan.keep.single.tiers, contains(BackupTier.monthly));
    });
  });

  group('GFS — time-of-day and time zones', () {
    test('midnight and 23:59:59 on the same day decide identically', () {
      final present = [DateTime.utc(2026, 7, 9)];
      final atMidnight = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15, 0, 0, 0),
        presentDates: present,
      );
      final atLastSecond = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15, 23, 59, 59, 999),
        presentDates: present,
      );
      expect(
        atMidnight.keep.map((k) => k.date),
        atLastSecond.keep.map((k) => k.date),
      );
      expect(atMidnight.purge, atLastSecond.purge);
    });

    test('a local `now` reduces to ITS local date, not to its UTC date', () {
      // A device at UTC+X, 01:00 local, is still the previous day in UTC.
      // Normalization reads the LOCAL fields (year/month/day), so a backup
      // day is the day the person actually lived through.
      final localNow = DateTime(2026, 7, 15, 1, 30);
      final plan = GfsRetentionPlan.compute(
        now: localNow,
        presentDates: [DateTime(2026, 7, 15, 22, 0)],
      );
      expect(plan.keep.single.date, DateTime.utc(2026, 7, 15));
      expect(plan.purge, isEmpty);
    });

    test(
        'across a DST change, stepping back 7 days neither skips nor '
        'doubles a day', () {
      // 2026-10-25 is the European switch back to winter time: a 25-hour
      // day. Normalizing to UTC BEFORE any arithmetic is what protects
      // against `Duration(days:)` drifting by an hour in local time and
      // landing on the previous day.
      // MUTATION CHECK: were _dateOnly to use DateTime(...) (local) rather
      // than DateTime.utc(...), the subtractions would cross the DST
      // boundary and this test would land on shifted dates.
      final now = DateTime(2026, 10, 27, 3, 0); // Tuesday, after the switch
      final present = [
        for (var i = 0; i < 7; i++)
          DateTime.utc(2026, 10, 27).subtract(Duration(days: i)),
      ];
      final plan = GfsRetentionPlan.compute(now: now, presentDates: present);
      expect(plan.purge, isEmpty);
      expect(plan.keep, hasLength(7));
      expect(
        plan.keep.map((k) => k.date).toSet(),
        {
          for (var i = 0; i < 7; i++)
            DateTime.utc(2026, 10, 27).subtract(Duration(days: i)),
        },
      );
      // 20 October (D-7) must be excluded, not the 21st (D-6).
      expect(
        plan.keep.map((k) => k.date),
        contains(DateTime.utc(2026, 10, 21)),
      );
      expect(
        plan.keep.map((k) => k.date),
        isNot(contains(DateTime.utc(2026, 10, 20))),
      );
    });
  });

  group('GFS — a generation dated in the future', () {
    test('a generation dated tomorrow is NOT purged', () {
      // Every tier looks backwards (today - i), so the future is this
      // plan's blind spot — but a blind spot is not a licence to delete.
      // Two devices in different time zones, or one clock running fast,
      // is enough: one writes `<prefix>-2026-07-16.enc`, the other rotates
      // with today = 2026-07-15. Erasing a backup that was just written is
      // the worst thing a rotation can do.
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15),
        presentDates: [DateTime.utc(2026, 7, 16)],
      );
      expect(plan.purge, isEmpty);
      expect(plan.keep, isEmpty);
      expect(plan.ignored, [DateTime.utc(2026, 7, 16)]);
    });

    test('future dates are reported newest first, never mixed into purge', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15),
        presentDates: [
          DateTime.utc(2026, 7, 19), // a Sunday, in the future
          DateTime.utc(2026, 8, 1), // the 1st of a month, in the future
          DateTime.utc(2024, 3, 14), // genuinely stale
        ],
      );
      expect(plan.ignored, [
        DateTime.utc(2026, 8, 1),
        DateTime.utc(2026, 7, 19),
      ]);
      expect(plan.purge, [DateTime.utc(2024, 3, 14)]);
      expect(plan.keep, isEmpty);
    });

    test('today is never "in the future", whatever the time of day', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15, 0, 0, 1),
        presentDates: [DateTime.utc(2026, 7, 15, 23, 59, 59)],
      );
      expect(plan.ignored, isEmpty);
      expect(plan.keep.single.tiers, contains(BackupTier.daily));
    });

    test('`ignored` is empty when nothing is dated ahead', () {
      final plan = GfsRetentionPlan.compute(
        now: DateTime.utc(2026, 7, 15),
        presentDates: [DateTime.utc(2026, 7, 14), DateTime.utc(2024, 1, 1)],
      );
      expect(plan.ignored, isEmpty);
    });
  });
}
