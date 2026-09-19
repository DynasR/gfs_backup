/// Pure Grandfather-Father-Son (GFS) retention logic for a daily backup
/// rotation.
///
/// Given a reference "today" and the set of calendar dates that currently
/// have a backup generation, decides which dates are worth keeping and
/// which are safe to purge. That is all it does: no I/O, no clock of its
/// own, no dependencies. The caller is the only one that lists and
/// deletes, so the decision can be replayed over any span of dates in a
/// test without a filesystem, a network or a mock.
///
/// Retention shape — one flat set of dated generations is enough, no
/// separate weekly or monthly copies are needed, because each tier is
/// *classified* from a generation's own date:
///   - **7 daily**: the 7 most recent calendar days present.
///   - **4 weekly**: the Sunday of each of the last 4 ISO weeks — the
///     generation dated that Sunday is kept as that week's
///     representative.
///   - **6 monthly**: the 1st of each of the last 6 months — the
///     generation dated the 1st is kept as that month's representative.
/// A date can satisfy more than one tier at once (e.g. today is both a
/// "daily" and, if it's a Sunday, a "weekly" — kept once, not duplicated).
/// Anything present but not selected by any tier is purged.
library;

/// One retained generation, with the tier(s) that justify keeping it.
///
/// Only [GfsRetentionPlan.compute] produces these.
class RetainedBackup {
  /// Binds a [date] to the non-empty set of [tiers] that retain it.
  const RetainedBackup({required this.date, required this.tiers});

  /// Calendar date (midnight UTC, no time-of-day) this generation
  /// represents.
  final DateTime date;

  /// Every tier this date qualifies for. Never empty for a retained date.
  final Set<BackupTier> tiers;
}

/// The three GFS tiers a retained generation can belong to.
enum BackupTier {
  /// One of the most recent calendar days.
  daily,

  /// The Sunday standing for one of the recent weeks.
  weekly,

  /// The 1st of the month standing for one of the recent months.
  monthly,
}

/// The decision produced by [compute]: which dated generations to keep,
/// and which to purge.
class GfsRetentionPlan {
  /// Wraps an already-computed decision. Use [compute] to derive one.
  const GfsRetentionPlan({required this.keep, required this.purge});

  /// Generations to keep, newest first, each with its justifying tier(s).
  final List<RetainedBackup> keep;

  /// Dates to delete, newest first — present, but retained by no tier.
  final List<DateTime> purge;

  /// Classifies [presentDates] against [now] and returns the retention
  /// decision. [presentDates] need not be sorted or deduplicated, and
  /// time-of-day is ignored throughout: every date is reduced to a
  /// midnight-UTC calendar date first. A tier whose date is absent from
  /// [presentDates] simply yields nothing — the plan never invents a
  /// generation, and never keeps a date that is not present.
  static GfsRetentionPlan compute({
    required DateTime now,
    required Iterable<DateTime> presentDates,
  }) {
    final today = _dateOnly(now);
    final present = presentDates.map(_dateOnly).toSet();

    final keepMap = <DateTime, Set<BackupTier>>{};

    // Daily: the 7 most recent calendar days up to and including today,
    // restricted to dates that actually exist on the backend.
    for (var i = 0; i < 7; i++) {
      final d = today.subtract(Duration(days: i));
      if (present.contains(d)) {
        keepMap.putIfAbsent(d, () => {}).add(BackupTier.daily);
      }
    }

    // Weekly: the Sunday of each of the last 4 ISO weeks (this week's
    // Sunday back through 3 weeks ago), restricted to dates present.
    // DateTime.weekday: Monday=1 .. Sunday=7.
    final daysSinceSunday = today.weekday % 7; // Sunday(7)->0, Monday(1)->1
    final thisWeekSunday = today.subtract(Duration(days: daysSinceSunday));
    for (var i = 0; i < 4; i++) {
      final sunday = thisWeekSunday.subtract(Duration(days: 7 * i));
      if (present.contains(sunday)) {
        keepMap.putIfAbsent(sunday, () => {}).add(BackupTier.weekly);
      }
    }

    // Monthly: the 1st of each of the last 6 months (this month back
    // through 5 months ago), restricted to dates present. `DateTime.utc`
    // normalizes an out-of-range month (e.g. month=0 -> December of the
    // previous year) on its own, so no manual year/month wraparound math
    // is needed here.
    for (var i = 0; i < 6; i++) {
      final firstOfMonth = DateTime.utc(today.year, today.month - i, 1);
      if (present.contains(firstOfMonth)) {
        keepMap.putIfAbsent(firstOfMonth, () => {}).add(BackupTier.monthly);
      }
    }

    final keep = keepMap.entries
        .map((e) => RetainedBackup(date: e.key, tiers: e.value))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final purge = present.difference(keepMap.keys.toSet()).toList()
      ..sort((a, b) => b.compareTo(a));

    return GfsRetentionPlan(keep: keep, purge: purge);
  }

  static DateTime _dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);
}
