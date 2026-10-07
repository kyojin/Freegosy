import 'dart:io' as io;
import 'package:flutter/material.dart';
import '../romm/romm_service.dart';
import 'backup_repository.dart';
import 'backup_entry.dart';
import 'save_operation_lock.dart';

import '../../main.dart' show scaffoldMessengerKey;

/// Processes pending local backups serially to avoid network and CPU spikes.
class BackgroundSyncQueue {
  static bool _isRunning = false;

  /// Starts processing the queue serially. Safe to call multiple times;
  /// it will simply return if already running.
  static Future<void> processQueue(
    RommService rommService,
    BackupRepository backupRepo, [
    ScaffoldMessengerState? customMessenger,
  ]) async {
    debugPrint('[BackgroundSyncQueue] processQueue triggered.');
    if (_isRunning) {
      debugPrint('[BackgroundSyncQueue] Queue is already running. Bailing.');
      return;
    }

    _isRunning = true;
    try {
      await _processQueue(rommService, backupRepo, customMessenger);
    } finally {
      _isRunning = false;
    }
  }

  static Future<void> _processQueue(
    RommService rommService,
    BackupRepository backupRepo,
    ScaffoldMessengerState? customMessenger,
  ) async {
    final newestPerGame = <String, BackupEntry>{};
    for (final item in backupRepo.getUnsyncedEntries()) {
      final existing = newestPerGame[item.romId];
      if (existing == null ||
          item.entry.timestamp.isAfter(existing.timestamp)) {
        newestPerGame[item.romId] = item.entry;
      }
    }
    final games = newestPerGame.entries.toList()
      ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    final pending = games.map((item) => item.key).toList();
    if (pending.isEmpty) return;

    int syncedCount = 0;

    final messenger = customMessenger ?? scaffoldMessengerKey.currentState;

    messenger?.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1565C0),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Syncing',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    'Syncing ${pending.length} offline saves to cloud...',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    for (final romId in pending) {
      if (rommService.isOffline.value) break;
      try {
        final uri = Uri.parse(rommService.config.baseUrl);
        final socket = await io.Socket.connect(
          uri.host,
          uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port,
          timeout: const Duration(seconds: 3),
        );
        await socket.close();
      } catch (_) {
        debugPrint(
          '[BackgroundSyncQueue] Connectivity check failed. Stopping queue.',
        );
        break;
      }

      // Fetch display metadata before taking the lock: a normal push can
      // retire this retry while metadata is in flight.
      final game = await rommService.getGame(romId);
      final result = await SaveOperationLock.run<bool?>(romId, (_) async {
        if (rommService.isOffline.value) return false;
        final entry = backupRepo.newestPending(romId);
        if (entry == null) return null;
        final zipFile = io.File(entry.localZipPath);
        if (!await zipFile.exists()) {
          await backupRepo.markAsSynced(romId, entry);
          return null;
        }
        final covered = backupRepo
            .getEntries(romId)
            .where((e) => !e.isSynced && !e.timestamp.isAfter(entry.timestamp))
            .toList();
        final displayStem =
            game?.displayName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_') ??
            'freegosy_$romId';
        debugPrint('[BackgroundSyncQueue] Pushing ${zipFile.path} to RomM...');
        final uploaded = await rommService.uploadSave(
          romId,
          zipFile,
          overrideFilename: '$displayStem.zip',
        );
        if (uploaded.ok) await backupRepo.acknowledgeEntries(romId, covered);
        return uploaded.ok;
      });
      if (result == false) break;
      if (result == true) {
        syncedCount++;
        // Throttle outside the lock so a normal push is not delayed.
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }

    if (syncedCount > 0) {
      messenger?.showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF2E7D32),
          duration: const Duration(seconds: 3),
          content: Row(
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cloud Sync',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'Cloud sync complete. $syncedCount saves uploaded.',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }
}
