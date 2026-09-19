# Changelog

## 0.1.0

First release.

- `GfsRetentionPlan` — pure 7 daily / 4 weekly / 6 monthly classification of a
  set of dated generations into what to keep (with the justifying tiers) and
  what to purge.
- `BackupBackend` — the four-method storage surface the rotation needs.
- `GfsBackupService` — snapshot, seal, upload and rotate, in either
  `flatDaily` or `tieredFolders` mode.
- `LocalArchiveRotator` — the same retention against a caller-supplied local
  sink, with no backend and no cloud configuration.
