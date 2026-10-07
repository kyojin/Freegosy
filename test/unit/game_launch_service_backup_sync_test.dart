import 'dart:io' as io;
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/backup_entry.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import '../helpers/game_launch_service_fakes.dart';

final _game = Game(
  id: '42',
  name: 'Ico (SCUS-97113)',
  platformSlug: 'ps2',
  fileSize: 0,
);

void main() {
  group('post-exit backups and restart sync', () {
    late io.Directory tempDir;
    late io.File backupZip;
    late BackupRepository repository;

    GameSession exited() => GameSession(
      process: ExitedTestProcess(),
      sessionStart: DateTime(2026, 1, 1),
      emulatorId: 'pcsx2',
      activityTrackerFuture: Future.value(null),
    );

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('post_exit_backup_');
      Hive.init(tempDir.path);
      if (!Hive.isAdapterRegistered(1))
        Hive.registerAdapter(BackupEntryAdapter());
      await Hive.openBox<List>('freegosy_backups');
      repository = BackupRepository()..initBox();
      final archive = Archive()
        ..addFile(ArchiveFile.string('save.bin', 'local restore point'));
      backupZip = io.File(p.join(tempDir.path, 'backup.zip'));
      await backupZip.writeAsBytes(ZipEncoder().encode(archive));
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    Future<BackupRepository> reopenRepository() async {
      await Hive.close();
      await Hive.openBox<List>('freegosy_backups');
      return BackupRepository()..initBox();
    }

    for (final (label, pushOk, blockedReason, queued) in [
      ('successful push', true, null, false),
      ('failed push', false, null, true),
      ('blocked save', false, 'serial unavailable', false),
      ('skipped push', false, null, false),
    ]) {
      test(
        '$label preserves the backup and its retry eligibility after restart',
        () async {
          final service = await launchServiceLogging(
            [],
            pushOk: pushOk,
            pushResult: label == 'skipped push' ? SavePushResult.skipped : null,
            blockedReason: blockedReason,
            backupService: FixedBackupService(backupZip.path),
            backupRepository: repository,
          );

          final result = await service.awaitExitAndSync(
            exited(),
            _game,
            'Ico.iso',
            syncMode: 'both',
          );

          expect(result!.syncOk, pushOk);
          expect(result.saveSyncBlocked, blockedReason);
          expect(result.backupZipPath, backupZip.path);
          final reopened = await reopenRepository();
          final entry = reopened.getEntries(_game.id).single;
          expect(entry.isSynced, !queued);
          expect(
            reopened.getUnsyncedEntries(),
            queued ? hasLength(1) : isEmpty,
          );
          expect(await backupZip.exists(), isTrue);
          final restored = ZipDecoder().decodeBytes(
            await backupZip.readAsBytes(),
          );
          expect(restored.files.single.name, 'save.bin');
        },
      );
    }

    test(
      'a successful push supersedes older retries without deleting restore points',
      () async {
        final olderZip = await backupZip.copy(
          p.join(tempDir.path, 'older.zip'),
        );
        await repository.addEntry(
          _game.id,
          BackupEntry(
            timestamp: DateTime(2025),
            md5Hash: 'older',
            localZipPath: olderZip.path,
          ),
        );
        final service = await launchServiceLogging(
          [],
          backupService: FixedBackupService(backupZip.path),
          backupRepository: repository,
        );

        await service.awaitExitAndSync(
          exited(),
          _game,
          'Ico.iso',
          syncMode: 'both',
        );

        final reopened = await reopenRepository();
        expect(reopened.getEntries(_game.id), hasLength(2));
        expect(reopened.getUnsyncedEntries(), isEmpty);
        final older = reopened.getEntries(_game.id).last;
        expect(older.localZipPath, olderZip.path);
        expect(older.md5Hash, 'older');
        expect(older.timestamp, DateTime(2025));
        expect(older.isSynced, isTrue);
        expect(await olderZip.exists(), isTrue);
      },
    );

    test('a blocked push does not acknowledge older pending retries', () async {
      final olderZip = await backupZip.copy(p.join(tempDir.path, 'older.zip'));
      await repository.addEntry(
        _game.id,
        BackupEntry(
          timestamp: DateTime(2025),
          md5Hash: 'older',
          localZipPath: olderZip.path,
        ),
      );
      final service = await launchServiceLogging(
        [],
        blockedReason: 'serial unavailable',
        backupService: FixedBackupService(backupZip.path),
        backupRepository: repository,
      );
      await service.awaitExitAndSync(
        exited(),
        _game,
        'Ico.iso',
        syncMode: 'both',
      );
      final reopened = await reopenRepository();
      expect(
        reopened.getUnsyncedEntries().single.entry.localZipPath,
        olderZip.path,
      );
    });

    test(
      'a successful push acknowledges retries when backup capture fails',
      () async {
        await repository.addEntry(
          _game.id,
          BackupEntry(
            timestamp: DateTime(2025),
            md5Hash: 'older',
            localZipPath: backupZip.path,
          ),
        );
        final service = await launchServiceLogging(
          [],
          backupService: NullBackupService(),
          backupRepository: repository,
        );
        final result = await service.awaitExitAndSync(
          exited(),
          _game,
          'Ico.iso',
          syncMode: 'both',
        );
        expect(result!.syncOk, isTrue);
        expect(result.backupZipPath, isNull);
        final reopened = await reopenRepository();
        expect(reopened.getUnsyncedEntries(), isEmpty);
        expect(await backupZip.exists(), isTrue);
      },
    );

    test(
      'a checkpoint added during a push is not acknowledged by that push',
      () async {
        final concurrentZip = await backupZip.copy(
          p.join(tempDir.path, 'concurrent.zip'),
        );
        final service = await launchServiceLogging(
          [],
          backupService: NullBackupService(),
          backupRepository: repository,
          duringPush: () async {
            // Deliberately use an older timestamp: eligibility is based on the
            // captured entries, not solely on the wall clock.
            await repository.addEntry(
              _game.id,
              BackupEntry(
                timestamp: DateTime(2025),
                md5Hash: 'concurrent',
                localZipPath: concurrentZip.path,
              ),
            );
          },
        );
        await service.awaitExitAndSync(
          exited(),
          _game,
          'Ico.iso',
          syncMode: 'both',
        );
        final reopened = await reopenRepository();
        expect(
          reopened.getUnsyncedEntries().single.entry.localZipPath,
          concurrentZip.path,
        );
      },
    );

    test(
      'covered checkpoints leave newer retries and other games pending',
      () async {
        final otherGameZip = await backupZip.copy(
          p.join(tempDir.path, 'other.zip'),
        );
        final newerZip = await backupZip.copy(
          p.join(tempDir.path, 'newer.zip'),
        );
        await repository.addEntry(
          'other',
          BackupEntry(
            timestamp: DateTime(2025),
            md5Hash: 'other',
            localZipPath: otherGameZip.path,
          ),
        );
        await repository.addEntry(
          _game.id,
          BackupEntry(
            timestamp: DateTime(2099),
            md5Hash: 'newer',
            localZipPath: newerZip.path,
          ),
        );
        final service = await launchServiceLogging(
          [],
          backupService: FixedBackupService(backupZip.path),
          backupRepository: repository,
        );

        await service.awaitExitAndSync(
          exited(),
          _game,
          'Ico.iso',
          syncMode: 'both',
        );

        final reopened = await reopenRepository();
        expect(
          reopened.getUnsyncedEntries().map((e) => e.entry.localZipPath),
          unorderedEquals([otherGameZip.path, newerZip.path]),
        );
        expect(await otherGameZip.exists(), isTrue);
        expect(await newerZip.exists(), isTrue);
      },
    );

    test(
      'a save conflict does not create a backup queued to bypass the conflict',
      () async {
        final service = await launchServiceLogging(
          [],
          conflict: true,
          backupService: FixedBackupService(backupZip.path),
          backupRepository: repository,
        );

        await expectLater(
          service.awaitExitAndSync(
            exited(),
            _game,
            'Ico.iso',
            syncMode: 'both',
          ),
          throwsA(isA<SaveConflictException>()),
        );

        final reopened = await reopenRepository();
        expect(reopened.getEntries(_game.id), isEmpty);
        expect(reopened.getUnsyncedEntries(), isEmpty);
      },
    );
  });
}
