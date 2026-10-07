import 'dart:io' as io;
import 'package:dio/dio.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/backup_entry.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/backup_service.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/save_operation_lock.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A process that has already exited with code 0.
class ExitedTestProcess implements io.Process {
  @override
  Future<int> get exitCode => Future.value(0);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A SaveSyncService reporting a controlled push outcome.
class _RecordingSaveSync extends SaveSyncService {
  _RecordingSaveSync(
    super.romm,
    super.dirs,
    super.registry,
    super.prefs,
    this.log, {
    this.blockedReason,
    this.pushOk = true,
    this.conflict = false,
    this.pushResult,
    this.duringPush,
  });
  final List<String> log;

  /// When set, pushSaves reports that saves can't be synced, like a
  /// strategy's saveSyncBlockedReason does.
  final String? blockedReason;
  final bool pushOk;
  final bool conflict;
  final SavePushResult? pushResult;
  final Future<void> Function()? duringPush;

  @override
  Future<SavePushResult> pushSavesWithResult(
    Game game,
    String romPath, {
    DateTime? sessionStart,
    String syncMode = 'both',
    bool force = false,
    String? coreOverride,
    String? emulatorId,
    SaveOperationLease? lease,
  }) async {
    log.add('push');
    if (blockedReason != null)
      throw SaveSyncNotPossibleException(blockedReason!);
    if (conflict) {
      throw SaveConflictException(
        game: game,
        localTime: DateTime(2026),
        cloudTime: DateTime(2026, 2),
      );
    }
    await duringPush?.call();
    return pushResult ??
        (pushOk ? SavePushResult.synced : SavePushResult.failed);
  }
}

/// A GameLaunchService whose save push appends 'push' to [log].
Future<GameLaunchService> launchServiceLogging(
  List<String> log, {
  String? blockedReason,
  bool pushOk = true,
  bool conflict = false,
  BackupService? backupService,
  BackupRepository? backupRepository,
  SavePushResult? pushResult,
  Future<void> Function()? duringPush,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = SharedPreferencesAppPreferences(
    await SharedPreferences.getInstance(),
  );
  final dirService = DirectoryService(prefs);
  final registry = StrategyRegistry(dirService, prefs);
  final rommService = RommService(
    RomMConfig(
      baseUrl: 'https://romm.example.com',
      username: '',
      password: '',
      apiKey: 'k',
    ),
    dio: Dio(BaseOptions(baseUrl: 'https://romm.example.com')),
    skipConnectivityCheck: true,
  );
  return GameLaunchService(
    directoryService: dirService,
    strategyRegistry: registry,
    saveSyncService: _RecordingSaveSync(
      rommService,
      dirService,
      registry,
      prefs,
      log,
      blockedReason: blockedReason,
      pushOk: pushOk,
      conflict: conflict,
      pushResult: pushResult,
      duringPush: duringPush,
    ),
    backupService: backupService ?? BackupService(),
    backupRepository: backupRepository ?? _EmptyBackupRepository(),
    prefs: prefs,
  );
}

/// Supplies an existing restore point while the real repository persists it.
class FixedBackupService extends BackupService {
  FixedBackupService(this.zipPath);
  final String zipPath;

  @override
  Future<BackupResult?> createImmediate(
    Game game,
    String romPath,
    SaveSyncService syncService, {
    String? emulatorId,
  }) async => (zipPath: zipPath, md5: 'checkpoint');
}

class NullBackupService extends BackupService {
  @override
  Future<BackupResult?> createImmediate(
    Game game,
    String romPath,
    SaveSyncService syncService, {
    String? emulatorId,
  }) async => null;
}

/// Tests without restore points do not need a Hive box.
class _EmptyBackupRepository extends BackupRepository {
  @override
  List<BackupEntry> getEntries(String romId) => [];
}
