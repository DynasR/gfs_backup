import 'dart:typed_data';

/// The whole contract between `GfsBackupService` and your storage: four
/// operations, deliberately the smallest set a GFS rotation needs.
///
/// Implement it over whatever you already have — a cloud drive client,
/// an object store, an SFTP session, a plain directory — and the backup
/// and rotation machinery works unchanged. Paths are relative to a root
/// the implementation picks: this package never sees an absolute location
/// and never holds a credential.
abstract class BackupBackend {
  /// Writes [bytes] to [relativePath], creating intermediate folders as
  /// needed. Overwriting an existing path must succeed.
  Future<void> uploadTo(String relativePath, Uint8List bytes);

  /// Downloads the file at [relativePath], or `null` if it does not exist.
  Future<Uint8List?> downloadFrom(String relativePath);

  /// Lists the file names (leaf names, not full paths) directly under
  /// [folderPath]. Returns an empty list if the folder does not exist yet
  /// — "nothing there" is an answer, not an error.
  Future<List<String>> listFiles(String folderPath);

  /// Deletes the file at [relativePath] if it exists; a no-op if it
  /// doesn't ("already gone" is success, not failure).
  Future<void> deleteFile(String relativePath);
}
