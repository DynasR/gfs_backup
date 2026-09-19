# gfs_backup

Grandfather-Father-Son backup retention and rotation, in pure Dart, with **no
dependencies**.

Keeping every backup forever is not a policy, and keeping only the last one is
not a backup. GFS is the classic answer: keep the last few days in full, one
generation per recent week, one per recent month. Recent mistakes are
recoverable to the day, older ones to the month, and storage stays bounded
instead of growing without end.

This package is that policy and nothing else. It holds no key, no credential,
and no opinion about where your bytes go.

```
7 daily   the 7 most recent calendar days present
4 weekly  the Sunday of each of the last 4 weeks
6 monthly the 1st of each of the last 6 months
```

A date can satisfy several tiers at once — today's generation on a Sunday the
1st is the daily, the weekly and the monthly, stored once. Anything present
that no tier claims is purged.

## Install

```yaml
dependencies:
  gfs_backup: ^0.1.0
```

## Just the decision

`GfsRetentionPlan` is pure: it takes a reference "today" and the dates you
currently hold, and answers what to keep and what to purge. No I/O, no clock of
its own, no globals — which is why a year of rotation can be replayed in a unit
test in under a millisecond.

```dart
import 'package:gfs_backup/gfs_backup.dart';

final plan = GfsRetentionPlan.compute(
  now: DateTime.utc(2026, 7, 15),
  presentDates: [
    DateTime.utc(2026, 7, 15), // today
    DateTime.utc(2026, 7, 12), // Sunday
    DateTime.utc(2026, 7, 1),  // 1st of the month
    DateTime.utc(2026, 2, 3),  // stale
  ],
);

for (final kept in plan.keep) {
  print('${kept.date} kept as ${kept.tiers}'); // e.g. {weekly, monthly}
}
print(plan.purge); // [2026-02-03] — delete these
```

Use it on its own over anything you can enumerate by date: object storage keys,
a directory listing, rows in a table. Nothing forces you into the rest of the
package.

## The full rotation, over your own storage

`GfsBackupService` writes one generation per day and rotates what is already
there. It reaches your storage through `BackupBackend` — four methods, which is
the entire contract:

```dart
abstract class BackupBackend {
  Future<void> uploadTo(String relativePath, Uint8List bytes);
  Future<Uint8List?> downloadFrom(String relativePath);
  Future<List<String>> listFiles(String folderPath);
  Future<void> deleteFile(String relativePath);
}
```

Implement it over a cloud drive client, an object store, an SFTP session or a
plain directory, and the rotation works unchanged:

```dart
final service = GfsBackupService(
  filePrefix: 'myapp',
  backend: myBackend,
  snapshotBytes: () => database.vacuumIntoBytes(),
  seal: (plaintext, isoDate) => myCipher.encrypt(plaintext, aad: isoDate),
);

final run = await service.backupNow();
print(run.uploadedPath); // b/daily/myapp-2026-07-15.enc
print(run.purged);       // dates deleted by this run
```

Encryption is a callback, never a dependency: `seal` receives the generation's
ISO date, which is exactly what you need to bind a ciphertext to the day it
stands for. If you do not encrypt, return the bytes unchanged.

Two rotation shapes are available:

| `GfsRotationMode` | Layout | Rotation |
| --- | --- | --- |
| `flatDaily` (default) | one folder, one file per day | classified by `GfsRetentionPlan` |
| `tieredFolders` | daily + weekly + monthly folders | Sundays and 1sts are copied up, each folder pruned to its own count |

`flatDaily` stores the least; `tieredFolders` costs extra copies but survives
the daily folder being wiped and reads plainly to a human browsing the backend.

## No cloud at all

`LocalArchiveRotator` applies the same retention to a local sink — four
callbacks, so a `Directory` on desktop and a Storage Access Framework tree on
Android are the same code, and a `Map` in a test is too:

```dart
final rotator = LocalArchiveRotator(
  filePrefix: 'myapp',
  snapshotBytes: () => database.vacuumIntoBytes(),
  write: (name, bytes) => File('$archiveDir/$name').writeAsBytes(bytes),
  list: () async => Directory(archiveDir).listSync().map(basename).toList(),
  delete: (name) async => File('$archiveDir/$name').delete().then((_) => true),
);

final run = await rotator.archiveNow();
print(run.writtenFileName); // myapp-2026-07-15.sqlite
print(run.purged);          // files ACTUALLY deleted, not merely attempted
```

Re-running on the same day overwrites rather than duplicating, so a "backup on
launch" is safe to call as often as you like.

## Things it deliberately does not do

- **No network, no filesystem, no platform channels.** Every side effect is a
  callback you supply. The package imports `dart:typed_data` and nothing else.
- **No encryption.** A sealer callback, not a cipher. Your format, your key
  management, your migration path.
- **No scheduler.** Call `backupNow()` when your app decides it is due. There
  is no background isolate quietly running behind your back.
- **No files of yours are touched.** Anything whose name does not match
  `<filePrefix>-<yyyy-mm-dd><suffix>` is foreign to the rotation, and so can
  never be purged by it.

## Known limits

Honest, and locked by characterization tests in `test/`:

- **A generation dated in the future is purged on the next rotation.** All
  three tiers look backwards from "today". Two devices in different time zones,
  or one clock running fast, can therefore erase a backup that was just
  written. Keep one clock authoritative, or pass a `now` you control.
- **`GfsBackupService.parseDateFromFileName` does not check field widths** (it
  accepts `myapp-26-7-1.enc`), while `LocalArchiveRotator` demands `4-2-2`. A
  name written by something other than this package, and not zero-padded, is
  parsed into an implausible date and then "purged" under a padded name that
  does not exist: the real file survives and the run report claims a deletion
  that never happened. Files this package writes are always zero-padded.
- **Out-of-range months and days overflow rather than being rejected**
  (`2026-13-45` becomes `2027-02-14`), a consequence of `DateTime.utc`
  normalization.

## Tests

Around 1300 lines of tests for roughly 400 lines of source, run with
`dart test`. They cover the boundary of each tier from both sides, daylight
saving transitions, leap years, year wraps, non-UTC inputs, empty and
degenerate inputs, foreign file names, partial-failure propagation, and the
ordering guarantee that nothing is ever purged before the new generation is
safely written.

## License

MIT
