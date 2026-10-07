import 'dart:io' as io;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/backup_entry.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/storage/app_preferences.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:path/path.dart' as p;
import 'package:hive/hive.dart';
import '../helpers/game_launch_service_fakes.dart';

class _Prefs implements AppPreferences {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  String? getString(String key) => values[key];
  @override
  bool? getBool(String key) => null;
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Future<bool> setString(String key, String value) async {
    if (failWrites) throw io.FileSystemException('metadata write failed');
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) async => true;
  @override
  Future<bool> remove(String key) async => values.remove(key) != null;
}

class _Strategy extends SaveStrategy {
  _Strategy(this.file);
  final io.File file;
  bool changed = true;
  @override
  String get strategyId => 'mgba';
  @override
  bool get shouldZip => false;
  @override
  Future<String?> getSaveDir(Game game, String romPath) async =>
      file.parent.path;
  @override
  Future<List<io.File>> getSaveFiles(
    Game game,
    String romPath, {
    DateTime? sessionStart,
    String syncMode = 'both',
  }) async => sessionStart != null && !changed ? [] : [file];
  @override
  Future<bool> restoreSave(
    Game game,
    String destPath,
    Uint8List data,
    String filename,
  ) async => false;
}

class _Sync extends SaveSyncService {
  _Sync(super.romm, super.dirs, super.registry, super.prefs, this.strategy);
  final SaveStrategy strategy;
  @override
  SaveStrategy getStrategyForGame(Game game, {String? emulatorId}) => strategy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['4.8.1', '4.9.0']) {
    group('push outcomes on RomM $version', () {
      late io.Directory temp;
      late _Prefs prefs;
      late _Strategy strategy;
      late _Sync sync;
      late DirectoryService dirs;
      late StrategyRegistry registry;
      late List<RequestOptions> requests;
      var uploadStatus = 200;
      final game = Game(
        id: '42',
        name: 'game',
        platformSlug: 'gba',
        fileSize: 0,
      );

      setUp(() async {
        temp = await io.Directory.systemTemp.createTemp('push_result_');
        prefs = _Prefs();
        final file = await io.File(
          p.join(temp.path, 'game.sav'),
        ).writeAsBytes(List.filled(150, 1));
        strategy = _Strategy(file);
        requests = [];
        uploadStatus = 200;
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (options.path == '/api/heartbeat') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'SYSTEM': {'VERSION': version},
                    },
                  ),
                );
              } else if (options.path == '/api/saves' &&
                  options.method == 'GET') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'items': <dynamic>[]},
                  ),
                );
              } else if (options.path == '/api/saves' &&
                  options.method == 'POST') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: uploadStatus,
                    data: uploadStatus == 200 ? {'id': 1} : {},
                  ),
                );
              } else {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    error: 'Unexpected request ${options.uri}',
                  ),
                );
              }
            },
          ),
        );
        final romm = RommService(
          RomMConfig(
            baseUrl: 'https://romm.example.com',
            username: '',
            password: '',
          ),
          dio: dio,
          prefs: prefs,
          skipConnectivityCheck: true,
        );
        dirs = DirectoryService(prefs, platform: const PlatformInfo('windows'))
          ..romsRootPath = temp.path
          ..emulatorsRootPath = temp.path;
        registry = StrategyRegistry(dirs, prefs);
        sync = _Sync(romm, dirs, registry, prefs, strategy);
      });

      tearDown(() async {
        await Hive.close();
        await temp.delete(recursive: true);
      });

      Future<BackupRepository> repository() async {
        Hive.init(temp.path);
        if (!Hive.isAdapterRegistered(1))
          Hive.registerAdapter(BackupEntryAdapter());
        await Hive.openBox<List>('freegosy_backups');
        return BackupRepository()..initBox();
      }

      GameSession session() => GameSession(
        process: ExitedTestProcess(),
        sessionStart: DateTime.now(),
        emulatorId: 'mgba',
        activityTrackerFuture: Future.value(null),
      );

      test(
        'real post-exit push acknowledges retries even without a backup',
        () async {
          final repo = await repository();
          await repo.addEntry(
            game.id,
            BackupEntry(
              timestamp: DateTime(2025),
              md5Hash: 'older',
              localZipPath: 'older.zip',
            ),
          );
          final launch = GameLaunchService(
            directoryService: dirs,
            strategyRegistry: registry,
            saveSyncService: sync,
            backupService: NullBackupService(),
            backupRepository: repo,
            prefs: prefs,
          );

          final result = await launch
              .awaitExitAndSync(session(), game, 'game.gba', syncMode: 'both')
              .timeout(const Duration(seconds: 5));

          expect(result!.syncOk, isTrue);
          expect(result.backupZipPath, isNull);
          expect(repo.getUnsyncedEntries(), isEmpty);
          expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        },
      );

      test(
        'a real no-change exit preserves a backup without queuing it',
        () async {
          expect(await sync.pushSaves(game, 'game.gba'), isTrue);
          strategy.changed = false;
          final archive = Archive()
            ..addFile(ArchiveFile.string('save.bin', 'checkpoint'));
          final backup = await io.File(
            p.join(temp.path, 'checkpoint.zip'),
          ).writeAsBytes(ZipEncoder().encode(archive));
          final repo = await repository();
          final launch = GameLaunchService(
            directoryService: dirs,
            strategyRegistry: registry,
            saveSyncService: sync,
            backupService: FixedBackupService(backup.path),
            backupRepository: repo,
            prefs: prefs,
          );

          final result = await launch
              .awaitExitAndSync(session(), game, 'game.gba', syncMode: 'both')
              .timeout(const Duration(seconds: 5));

          expect(result!.syncOk, isFalse);
          expect(repo.getEntries(game.id).single.localZipPath, backup.path);
          expect(repo.getUnsyncedEntries(), isEmpty);
          expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        },
      );

      test('no session changes are skipped without an upload', () async {
        strategy.changed = false;
        expect(
          await sync.pushSavesWithResult(
            game,
            'game.gba',
            sessionStart: DateTime.now(),
          ),
          SavePushResult.skipped,
        );
        expect(
          await sync.pushSaves(game, 'game.gba', sessionStart: DateTime.now()),
          isFalse,
        );
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      });

      test('invalid small saves are skipped without an upload', () async {
        await strategy.file.writeAsBytes(List.filled(10, 1));
        expect(
          await sync.pushSavesWithResult(game, 'game.gba'),
          SavePushResult.skipped,
        );
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      });

      test('a rejected HTTP upload remains retryable', () async {
        uploadStatus = 503;
        expect(
          await sync.pushSavesWithResult(game, 'game.gba'),
          SavePushResult.failed,
        );
      });

      test(
        'accepted saves remain successful when local metadata cannot be stored',
        () async {
          prefs.failWrites = true;
          expect(
            await sync.pushSavesWithResult(game, 'game.gba'),
            SavePushResult.synced,
          );
          expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        },
      );

      test(
        'unchanged successfully uploaded bytes remain synced without another POST',
        () async {
          expect(
            await sync.pushSavesWithResult(game, 'game.gba'),
            SavePushResult.synced,
          );
          expect(
            await sync.pushSavesWithResult(game, 'game.gba'),
            SavePushResult.synced,
          );
          expect(await sync.pushSaves(game, 'game.gba'), isTrue);
          expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        },
      );
    });
  }
}
