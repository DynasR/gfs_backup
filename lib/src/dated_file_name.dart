/// Shared parsing of the `<prefix>-<yyyy-mm-dd><suffix>` names every
/// rotation in this package writes, so that no two of them can ever
/// disagree about what a file name means.
library;

final _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Parses the calendar date out of `<prefix>-<yyyy-mm-dd><suffix>`, or
/// returns `null` for any name that does not match that exact shape.
///
/// Strict on purpose: year, month and day must be zero-padded to exactly
/// 4, 2 and 2 digits, and must denote a real calendar date — `13` is not a
/// month, and 30 February is not a day. A name this function rejects is
/// *foreign*: the rotation that owns the folder will neither count it nor
/// delete it.
///
/// The strictness is what keeps a rotation honest. `DateTime.utc`
/// normalizes out-of-range input instead of refusing it — `2026-13-45`
/// quietly becomes 2027-02-14 — so a lenient parser turns a corrupted name
/// into a plausible date, then tries to delete the zero-padded name that
/// date implies, which is a different file and usually no file at all. The
/// corrupted one survives and the run reports a deletion that never
/// happened. Refusing to parse it is both safer and truthful.
DateTime? parseDatedFileName(
  String name, {
  required String prefix,
  required String suffix,
}) {
  if (!name.startsWith('$prefix-') || !name.endsWith(suffix)) return null;
  final start = prefix.length + 1;
  final end = name.length - suffix.length;
  // A prefix and a suffix can overlap on a short enough name.
  if (end < start) return null;

  final match = _isoDate.firstMatch(name.substring(start, end));
  if (match == null) return null;

  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  // Round-tripping the fields is the cheapest way to tell a real date from
  // one `DateTime.utc` silently normalized into existence.
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}
