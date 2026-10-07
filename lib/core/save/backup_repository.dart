import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'backup_entry.dart';

/// Hive-backed repository that persists up to [_maxBackups] local backup
/// entries per game ROM. Business logic (rotation, disk cleanup) lives here
/// so that providers stay thin.
class BackupRepository {
  static const String _boxName = 'freegosy_backups';
  static const int _maxBackups = 4;

  Box<List>? _box;

  /// Links the repository to the already-opened Hive box.
  void initBox() {
    if (_box != null && _box!.isOpen) return;
    _box = Hive.box<List>(_boxName);
  }

  Box<List> get _openBox {
    assert(_box != null && _box!.isOpen, 'BackupRepository: call initBox() first');
    return _box!;
  }

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------

  /// Returns the backup list for [romId], newest-first.
  List<BackupEntry> getEntries(String romId) {
    final raw = _openBox.get(romId);
    if (raw == null) return [];
    return raw.cast<BackupEntry>().toList();
  }

  /// Returns all unsynced entries across all games, along with their romId.
  List<({String romId, BackupEntry entry})> getUnsyncedEntries() {
    final unsynced = <({String romId, BackupEntry entry})>[];
    for (final key in _openBox.keys) {
      final romId = key.toString();
      final entries = getEntries(romId);
      for (final entry in entries) {
        if (!entry.isSynced) {
          unsynced.add((romId: romId, entry: entry));
        }
      }
    }
    // Sort oldest first so they get processed in order of creation
    unsynced.sort((a, b) => a.entry.timestamp.compareTo(b.entry.timestamp));
    return unsynced;
  }

  // ---------------------------------------------------------------------------
  // Write
  // ---------------------------------------------------------------------------

  /// Appends [entry] for [romId]. If the list would exceed [_maxBackups], the
  /// oldest entry is silently deleted from disk and removed from the DB.
  Future<void> addEntry(String romId, BackupEntry entry) async {
    final entries = getEntries(romId);
    entries.insert(0, entry); // newest first

    if (entries.length > _maxBackups) {
      final overflow = entries.sublist(_maxBackups);
      entries.removeRange(_maxBackups, entries.length);
      for (final old in overflow) {
        await _deleteFile(old.localZipPath);
      }
    }

    await _openBox.put(romId, entries);
  }

  /// Removes a specific [entry] for [romId] and deletes its physical ZIP.
  Future<void> removeEntry(String romId, BackupEntry entry) async {
    final entries = getEntries(romId);
    entries.removeWhere((e) =>
        e.localZipPath == entry.localZipPath &&
        e.timestamp == entry.timestamp);
    await _openBox.put(romId, entries);
    await _deleteFile(entry.localZipPath);
  }

  /// Marks a specific [entry] as synced.
  Future<void> markAsSynced(String romId, BackupEntry entry) async {
    final entries = getEntries(romId);
    final index = entries.indexWhere(
      (e) =>
          e.localZipPath == entry.localZipPath &&
          e.timestamp == entry.timestamp,
    );
    if (index != -1) {
      entries[index] = _asSynced(entries[index]);
      await _openBox.put(romId, entries);
    }
  }

  /// Acknowledge only the retry snapshots captured before an upload began.
  /// Entries added while it was running remain eligible, even if their clock
  /// timestamps match. Restore-point files are kept.
  Future<void> acknowledgeEntries(
    String romId,
    List<BackupEntry> covered,
  ) async {
    if (covered.isEmpty) return;
    final keys = covered
        .map((e) => (e.localZipPath, e.timestamp, e.md5Hash))
        .toSet();
    final entries = getEntries(romId);
    var changed = false;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.isSynced &&
          keys.contains((entry.localZipPath, entry.timestamp, entry.md5Hash))) {
        entries[i] = _asSynced(entry);
        changed = true;
      }
    }
    if (changed) await _openBox.put(romId, entries);
  }

  /// Prefer the latest timestamp, keeping insertion order for ties.
  BackupEntry? newestPending(String romId) {
    BackupEntry? newest;
    for (final entry in getEntries(romId)) {
      if (!entry.isSynced &&
          (newest == null || entry.timestamp.isAfter(newest.timestamp))) {
        newest = entry;
      }
    }
    return newest;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static BackupEntry _asSynced(BackupEntry entry) => BackupEntry(
    timestamp: entry.timestamp,
    md5Hash: entry.md5Hash,
    localZipPath: entry.localZipPath,
    isSynced: true,
  );

  Future<void> _deleteFile(String path) async {
    try {
      final file = io.File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[BackupRepository] Could not delete backup file: $path ($e)');
    }
  }
}
