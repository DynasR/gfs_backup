# Changelog

## 0.1.0

First release.

- `GfsRetentionPlan` — pure 7 daily / 4 weekly / 6 monthly classification of a
  set of dated generations into what to keep (with the justifying tiers), what
  to purge, and what to leave alone. A date after the reference day is never
  purged: it lands in `ignored` instead, because clock skew must not cost you
  a backup that was just written.
- `BackupBackend` — the four-method storage surface the rotation needs.
- `GfsBackupService` — snapshot, seal, upload and rotate, in either
  `flatDaily` or `tieredFolders` mode.
- `LocalArchiveRotator` — the same retention against a caller-supplied local
  sink, with no backend and no cloud configuration.

Both rotations share one strict file-name parser: `<prefix>-<yyyy-mm-dd>` must
be zero-padded and denote a real calendar date, so a malformed name is treated
as foreign rather than normalized into a plausible date and acted upon.
