import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/cli/cli_config.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/strategies/mgba_save_strategy.dart';
import 'package:freegosy/core/save/strategies/windows_save_strategy.dart';
import 'package:freegosy/core/storage/app_preferences.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:freegosy/providers/romm_provider.dart';
import 'package:freegosy/providers/shared_prefs_provider.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'save_sync_service_test.mocks.dart';

class _PartialRestoreStrategy extends MgbaSaveStrategy {
  _PartialRestoreStrategy(super.directoryService);

  @override
  Future<bool> restoreSave(
    Game game,
    String romPath,
    Uint8List data,
    String filename,
  ) async {
    final saveDir = await getSaveDir(game, romPath);
    await File(p.join(saveDir!, 'game.sav')).writeAsBytes(data);
    return false;
  }
}

class _MutableDirectoryStrategy extends MgbaSaveStrategy {
  String saveDirectory;
  _MutableDirectoryStrategy(super.directoryService, this.saveDirectory);

  @override
  Future<String?> getSaveDir(Game game, String romPath) async => saveDirectory;
}

class _WindowsMetadataStrategy extends WindowsSaveStrategy {
  final String guessedDirectory;
  final String archiveDirectory;

  _WindowsMetadataStrategy(
    super.prefs,
    this.guessedDirectory,
    this.archiveDirectory,
  );

  @override
  Future<String?> getSaveDir(
    Game game,
    String romPath, {
    String? metadataSavePath,
  }) async =>
      getManualOverride(game.id) ?? metadataSavePath ?? guessedDirectory;

  @override
  Future<bool> restoreSave(
    Game game,
    String romPath,
    Uint8List data,
    String filename,
  ) async {
    final destination = getManualOverride(game.id) ?? archiveDirectory;
    await File(p.join(destination, 'game.sav')).writeAsBytes(data);
    return true;
  }
}

class _ArchiveTargetStrategy extends MgbaSaveStrategy {
  final String saveDirectory;
  final bool needsMapping;

  _ArchiveTargetStrategy(
    super.directoryService,
    this.saveDirectory, {
    this.needsMapping = false,
  });

  @override
  Future<String?> getSaveDir(Game game, String romPath) async {
    if (needsMapping) throw SaveMappingRequiredException();
    return null;
  }

  @override
  Future<bool> restoreSave(
    Game game,
    String romPath,
    Uint8List data,
    String filename,
  ) async {
    await File(p.join(saveDirectory, 'game.sav')).writeAsBytes(data);
    return true;
  }
}

class _StrategySaveSyncService extends SaveSyncService {
  final SaveStrategy strategy;

  _StrategySaveSyncService(
    super.rommService,
    super.directoryService,
    super.registry,
    super.prefs,
    this.strategy,
  );

  @override
  SaveStrategy getStrategyForGame(Game game, {String? emulatorId}) => strategy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RomMConfig config([String? slot]) => RomMConfig(
    baseUrl: 'https://romm.example.com',
    username: '',
    password: '',
    saveSlot: slot,
  );

  group('RomM save slot configuration', () {
    test('defaults to freegosy for new and pre-setting JSON configs', () {
      expect(config().saveSlot, 'freegosy');
      expect(
        RomMConfig.fromJson({'baseUrl': 'https://old.example.com'}).saveSlot,
        'freegosy',
      );
    });

    test('normalizes blanks and preserves custom names and case', () {
      expect(config('  ').saveSlot, 'freegosy');
      expect(config(' autosave ').saveSlot, 'autosave');
      expect(config('My playthrough / 2').saveSlot, 'My playthrough / 2');
      expect(RomMConfig.fromJson({'saveSlot': null}).saveSlot, 'freegosy');
      expect(RomMConfig.fromJson({'saveSlot': ''}).saveSlot, 'freegosy');
    });

    test('JSON and copyWith retain the configured slot', () {
      final original = config('autosave');
      expect(original.toJson()['saveSlot'], 'autosave');
      expect(RomMConfig.fromJson(original.toJson()).saveSlot, 'autosave');
      expect(original.copyWith(username: 'changed').saveSlot, 'autosave');
      expect(original.copyWith(saveSlot: 'custom').saveSlot, 'custom');
    });

    test('validates the server length limit using Unicode code points', () {
      expect(RomMConfig.validateSaveSlot('x' * 255), isNull);
      expect(RomMConfig.validateSaveSlot('x' * 256), isNotNull);
      expect(RomMConfig.validateSaveSlot('😀' * 255), isNull);
      expect(RomMConfig.validateSaveSlot('😀' * 256), isNotNull);
      expect(RomMConfig.validateSaveSlot('  autosave  '), isNull);
      expect(RomMConfig.validateSaveSlot(' ' * 256), isNull);
    });

    for (final slot in <String?>[null, 'autosave', 'custom']) {
      test('GUI and CLI load persisted slot ${slot ?? "(missing)"}', () async {
        SharedPreferences.setMockInitialValues({
          'rommBaseUrl': 'https://romm.example.com',
          RomMConfig.saveSlotPreferenceKey: ?slot,
        });
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        addTearDown(container.dispose);

        expect(
          (await container.read(rommConfigProvider.future)).saveSlot,
          slot ?? 'freegosy',
        );
        expect(
          (await loadCliRommConfig(
            SharedPreferencesAppPreferences(prefs),
          )).saveSlot,
          slot ?? 'freegosy',
        );
      });
    }
  });

  group('RomM slot sync', () {
    late Directory tempDir;
    late File localSave;
    late String romPath;
    late SharedPreferences prefs;
    late RommService romm;
    late SaveSyncService sync;
    late MockDirectoryService directory;
    late MockStrategyRegistry registry;
    late List<RequestOptions> requests;
    late List<Map<String, dynamic>> cloudSaves;
    late Set<int> syncedSaveIds;
    Future<void> Function(RequestOptions)? beforeResponse;
    var saveListStatus = 200;
    Object? saveListOverride;
    var version = '4.9.0';
    final game = Game(id: '42', name: 'game', platformSlug: 'gba', fileSize: 0);

    setUp(() async {
      version = '4.9.0';
      SharedPreferences.setMockInitialValues({'romm_device_id': 'device-1'});
      prefs = await SharedPreferences.getInstance();
      tempDir = await Directory.systemTemp.createTemp('romm_slot_test_');
      romPath = p.join(tempDir.path, 'game.gba');
      localSave = File(p.join(tempDir.path, 'game.sav'));
      await localSave.writeAsBytes(List.filled(150, 1));
      requests = [];
      syncedSaveIds = {};
      beforeResponse = null;
      saveListStatus = 200;
      saveListOverride = null;
      cloudSaves = [
        {
          'id': 1,
          'slot': 'freegosy',
          'file_name': 'game.sav',
          'created_at': '2025-01-02T00:00:00Z',
          'updated_at': '2025-01-02T00:00:00Z',
          'download_path': '/api/saves/1/content',
        },
        {
          'id': 2,
          'slot': 'autosave',
          'file_name': 'game.sav',
          'emulator': 'mgba',
          'created_at': '2025-01-01T00:00:00Z',
          'updated_at': '2025-01-01T00:00:00Z',
          'download_path': '/api/saves/2/content',
        },
      ];
      final dio = Dio();
      // Exercise the real API client and save strategy without network access.
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests.add(options);
            await beforeResponse?.call(options);
            final path = options.uri.path;
            dynamic data;
            if (path == '/api/heartbeat') {
              data = {
                'SYSTEM': {'VERSION': version},
              };
            } else if (path == '/api/saves' && options.method == 'GET') {
              data = {
                'items': cloudSaves
                    .map(
                      (save) => {
                        ...save,
                        'device_syncs': <dynamic>[
                          {
                            'device_id': 'device-1',
                            'is_current': syncedSaveIds.contains(save['id']),
                          },
                        ],
                      },
                    )
                    .toList(),
              };
              if (saveListOverride != null) data = saveListOverride;
            } else if (path == '/api/saves' && options.method == 'POST') {
              data = {'id': 3};
            } else if (path == '/api/saves/delete') {
              data = {};
            } else if (path == '/api/saves/1/content') {
              if (options.uri.queryParameters.containsKey('device_id'))
                syncedSaveIds.add(1);
              data = Uint8List.fromList(List.filled(150, 11));
            } else if (path == '/api/saves/2/content') {
              if (options.uri.queryParameters.containsKey('device_id'))
                syncedSaveIds.add(2);
              data = Uint8List.fromList(List.filled(150, 22));
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: 'Unexpected test request: ${options.uri}',
                ),
              );
              return;
            }
            final status = path == '/api/saves' && options.method == 'GET'
                ? saveListStatus
                : 200;
            handler.resolve(
              Response(requestOptions: options, statusCode: status, data: data),
            );
          },
        ),
      );
      romm = RommService(
        config(),
        dio: dio,
        prefs: SharedPreferencesAppPreferences(prefs),
        skipConnectivityCheck: true,
      );
      directory = MockDirectoryService();
      registry = MockStrategyRegistry();
      when(
        directory.getEmulatorDirectory('temp'),
      ).thenAnswer((_) async => tempDir.path);
      when(
        directory.getEmulatorAppSupportDirectory(
          any,
          platformSlug: anyNamed('platformSlug'),
        ),
      ).thenAnswer((_) async => p.join(tempDir.path, 'missing'));
      when(registry.getPreferredEmulatorId(any)).thenReturn(null);
      when(registry.getStrategyForSlug(any)).thenReturn(null);
      when(registry.getGameEmulatorPreference(any)).thenReturn(null);
      sync = SaveSyncService(
        romm,
        directory,
        registry,
        SharedPreferencesAppPreferences(prefs),
      );
    });

    tearDown(() async {
      romm.stopHeartbeat();
      await tempDir.delete(recursive: true);
    });

    List<RequestOptions> uploads() => requests
        .where((r) => r.uri.path == '/api/saves' && r.method == 'POST')
        .toList();
    List<RequestOptions> downloads() =>
        requests.where((r) => r.uri.path.endsWith('/content')).toList();

    SaveSyncService reloadSync() => SaveSyncService(
      romm,
      directory,
      registry,
      SharedPreferencesAppPreferences(prefs),
    );

    for (final serverVersion in ['4.8.1', '4.9.0']) {
      test(
        '$serverVersion an occupied new slot requires a local baseline before automatic push',
        () async {
          version = serverVersion;
          expect(await sync.pushSaves(game, romPath), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          await expectLater(
            sync.pushSaves(game, romPath),
            throwsA(
              isA<SaveConflictException>().having(
                (e) => e.targetSlot,
                'target slot',
                'autosave',
              ),
            ),
          );
          expect(uploads(), hasLength(1));
          expect(await sync.pullSave(game, romPath), isTrue);
          await localSave.writeAsBytes(List.filled(150, 33));
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads().last.queryParameters['slot'], 'autosave');
          expect(uploads().last.queryParameters['overwrite'], isNull);
        },
      );

      test(
        '$serverVersion a failed pull cannot enable an automatic cross-lineage overwrite',
        () async {
          version = serverVersion;
          expect(await sync.pullSave(game, romPath), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          cloudSaves[1]['download_path'] = null;
          expect(await sync.pullSave(game, romPath), isFalse);
          syncedSaveIds.add(
            2,
          ); // Even an optimistic server flag cannot prove a restore.
          await expectLater(
            sync.pushSaves(game, romPath),
            throwsA(isA<SaveConflictException>()),
          );
          expect(uploads(), isEmpty);
          expect(await localSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion a rejected save-list request cannot be treated as an empty slot',
        () async {
          version = serverVersion;
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          saveListStatus = 500;
          expect(await sync.pushSaves(game, romPath), isFalse);
          expect(uploads(), isEmpty);
        },
      );

      test(
        '$serverVersion a malformed save list cannot enable an automatic upload',
        () async {
          version = serverVersion;
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          saveListOverride = {'unexpected': 'response'};
          expect(await sync.pushSaves(game, romPath), isFalse);
          expect(uploads(), isEmpty);
        },
      );

      test(
        '$serverVersion invalid small saves are rejected before lineage conflicts',
        () async {
          version = serverVersion;
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          await localSave.writeAsBytes(List.filled(10, 1));
          expect(await sync.pushSaves(game, romPath), isFalse);
          expect(uploads(), isEmpty);
        },
      );

      test(
        '$serverVersion an upload records its captured source after a directory reconfiguration',
        () async {
          version = serverVersion;
          await localSave.writeAsBytes(List.filled(150, 11));
          final otherDirectory = Directory(p.join(tempDir.path, 'other'));
          await otherDirectory.create();
          final otherSave = File(p.join(otherDirectory.path, 'game.sav'));
          await otherSave.writeAsBytes(List.filled(150, 22));
          final strategy = _MutableDirectoryStrategy(directory, tempDir.path);
          final service = _StrategySaveSyncService(
            romm,
            directory,
            registry,
            SharedPreferencesAppPreferences(prefs),
            strategy,
          );
          beforeResponse = (options) async {
            if (options.uri.path == '/api/saves' && options.method == 'POST') {
              strategy.saveDirectory = otherDirectory.path;
              syncedSaveIds.add(1);
            }
          };
          expect(await service.pushSaves(game, romPath), isTrue);
          expect(await otherSave.readAsBytes(), List.filled(150, 22));
          expect(await service.pullSave(game, romPath), isTrue);
          expect(await otherSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion Windows archive metadata does not mark a guessed folder current',
        () async {
          version = serverVersion;
          final guessed = Directory(p.join(tempDir.path, 'guessed'));
          await guessed.create();
          final guessedSave = File(p.join(guessed.path, 'game.sav'));
          await guessedSave.writeAsBytes(List.filled(150, 11));
          final strategy = _WindowsMetadataStrategy(
            SharedPreferencesAppPreferences(prefs),
            guessed.path,
            tempDir.path,
          );
          final service = _StrategySaveSyncService(
            romm,
            directory,
            registry,
            SharedPreferencesAppPreferences(prefs),
            strategy,
          );
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(await service.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
          expect(await guessedSave.readAsBytes(), List.filled(150, 11));
          await strategy.setManualOverride(game.id, guessed.path);
          expect(
            await _StrategySaveSyncService(
              romm,
              directory,
              registry,
              SharedPreferencesAppPreferences(prefs),
              strategy,
            ).pullSave(game, romPath),
            isTrue,
          );
          expect(await guessedSave.readAsBytes(), List.filled(150, 22));
        },
      );

      test(
        '$serverVersion serializes a delayed upload and a new-slot restore across instances',
        () async {
          version = serverVersion;
          expect(await sync.pullSave(game, romPath), isTrue);
          final uploadStarted = Completer<void>();
          final finishUpload = Completer<void>();
          beforeResponse = (options) async {
            if (options.uri.path == '/api/saves' && options.method == 'POST') {
              if (!uploadStarted.isCompleted) uploadStarted.complete();
              await finishUpload.future;
            }
          };
          final oldPush = sync.pushSaves(game, romPath);
          addTearDown(() async {
            if (!finishUpload.isCompleted) finishUpload.complete();
            await oldPush;
          });
          await uploadStarted.future.timeout(const Duration(seconds: 5));

          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          final retainedNewService = reloadSync();
          final newPull = retainedNewService.pullSave(game, romPath);
          addTearDown(() async {
            if (!finishUpload.isCompleted) finishUpload.complete();
            await newPull;
          });
          await Future<void>.delayed(Duration.zero);
          expect(
            downloads(),
            hasLength(1),
            reason: 'The restore waits for the upload.',
          );
          finishUpload.complete();
          expect(await oldPush, isTrue);
          expect(await newPull, isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));

          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
          expect(await reloadSync().pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion a queued pull respects a launch timeout and can retry',
        () async {
          version = serverVersion;
          final uploadStarted = Completer<void>();
          final finishUpload = Completer<void>();
          beforeResponse = (options) async {
            if (options.uri.path == '/api/saves' && options.method == 'POST') {
              if (!uploadStarted.isCompleted) uploadStarted.complete();
              await finishUpload.future;
            }
          };
          final push = sync.pushSaves(game, romPath);
          addTearDown(() async {
            if (!finishUpload.isCompleted) finishUpload.complete();
            await push;
          });
          await uploadStarted.future.timeout(const Duration(seconds: 5));
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          final next = reloadSync();
          final guard = SaveRestoreGuard();
          final pull = guard.run(() => next.pullSave(game, romPath));
          addTearDown(() async {
            if (!finishUpload.isCompleted) finishUpload.complete();
            await pull;
          });
          guard.markTooLate();
          finishUpload.complete();
          expect(await push, isTrue);
          expect(await pull, isFalse);
          expect(downloads(), isEmpty);
          expect(await next.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );

      test(
        '$serverVersion aliases of one save destination share lineage tracking',
        () async {
          version = serverVersion;
          final aliasRomPath = p.join(tempDir.path, 'game.zip');
          expect(await sync.pullSave(game, romPath), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(await sync.pullSave(game, aliasRomPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
          expect(await reloadSync().pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion independent save directories retain their own lineage',
        () async {
          version = serverVersion;
          final first = Directory(p.join(tempDir.path, 'first'));
          final second = Directory(p.join(tempDir.path, 'second'));
          await first.create();
          await second.create();
          final firstSave = File(p.join(first.path, 'game.sav'));
          final secondSave = File(p.join(second.path, 'game.sav'));
          await firstSave.writeAsBytes(List.filled(150, 1));
          await secondSave.writeAsBytes(List.filled(150, 2));
          final firstRom = p.join(first.path, 'game.gba');
          final secondRom = p.join(second.path, 'game.gba');

          expect(await sync.pullSave(game, firstRom), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(await sync.pullSave(game, secondRom), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
          expect(await reloadSync().pullSave(game, firstRom), isFalse);
          expect(await firstSave.readAsBytes(), List.filled(150, 11));
          expect(await secondSave.readAsBytes(), List.filled(150, 22));

          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(await reloadSync().pullSave(game, firstRom), isTrue);
          expect(await firstSave.readAsBytes(), List.filled(150, 22));
        },
      );

      for (final needsMapping in [false, true]) {
        test(
          '$serverVersion an archive can resolve its target during restore (mapping=$needsMapping)',
          () async {
            version = serverVersion;
            expect(await sync.pullSave(game, romPath), isTrue);
            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
            final strategy = _ArchiveTargetStrategy(
              directory,
              tempDir.path,
              needsMapping: needsMapping,
            );
            SaveSyncService archiveSync() => _StrategySaveSyncService(
              romm,
              directory,
              registry,
              SharedPreferencesAppPreferences(prefs),
              strategy,
            );
            expect(await archiveSync().pullSave(game, romPath), isTrue);
            expect(await localSave.readAsBytes(), List.filled(150, 22));
            expect(await archiveSync().pullSave(game, romPath), isFalse);
            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
            expect(await reloadSync().pullSave(game, romPath), isTrue);
            expect(await localSave.readAsBytes(), List.filled(150, 11));
            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
            expect(await archiveSync().pullSave(game, romPath), isTrue);
            expect(await localSave.readAsBytes(), List.filled(150, 22));
          },
        );
      }

      test(
        '$serverVersion selects an overwritten save even if another was created later',
        () async {
          version = serverVersion;
          cloudSaves[1]['updated_at'] = '2025-01-03T00:00:00Z';
          cloudSaves.add({
            'id': 3,
            'slot': 'autosave',
            'file_name': 'game.sav',
            'created_at': '2025-01-02T00:00:00Z',
            'updated_at': '2025-01-02T00:00:00Z',
            'download_path': '/api/saves/1/content',
          });
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect((await romm.getLatestSave(game.id))?['id'], 2);
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );

      test(
        '$serverVersion a partial restore invalidates the previous lineage',
        () async {
          version = serverVersion;
          expect(await sync.pullSave(game, romPath), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          final failing = _StrategySaveSyncService(
            romm,
            directory,
            registry,
            SharedPreferencesAppPreferences(prefs),
            _PartialRestoreStrategy(directory),
          );
          await expectLater(failing.pullSave(game, romPath), throwsException);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
          expect(await reloadSync().pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion custom-slot cache keys cannot collide or clear each other',
        () async {
          version = serverVersion;
          final firstGame = Game(
            id: '7',
            name: '42_game',
            platformSlug: 'gba',
            fileSize: 0,
          );
          final firstRomPath = p.join(tempDir.path, '42_game.gba');
          await File(
            p.join(tempDir.path, '42_game.sav'),
          ).writeAsBytes(List.filled(150, 1));
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'campaign');
          expect(await sync.pushSaves(firstGame, firstRomPath), isTrue);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'campaign_7');
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads(), hasLength(2));

          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'campaign');
          await sync.clearHashCache(firstGame.id);
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'campaign_7');
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(
            uploads(),
            hasLength(2),
            reason: 'The other slot retains its cache.',
          );
        },
      );

      for (final slot in ['freegosy', 'autosave', 'custom']) {
        test(
          '$serverVersion push uses $slot and retains emulator metadata',
          () async {
            version = serverVersion;
            romm.updateConfig(config(slot));
            expect(await sync.pushSaves(game, romPath, force: true), isTrue);
            expect(uploads().single.queryParameters['slot'], slot);
            expect(uploads().single.queryParameters['emulator'], 'mgba');
            expect(uploads().single.queryParameters['autocleanup_limit'], '5');
            expect(
              uploads().single.queryParameters['device_id'],
              serverVersion == '4.9.0' ? 'device-1' : null,
            );
          },
        );
      }

      test(
        '$serverVersion pull prefers autosave over a newer freegosy save',
        () async {
          version = serverVersion;
          romm.updateConfig(config('autosave'));
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(downloads().single.uri.path, '/api/saves/2/content');
          expect(await localSave.readAsBytes(), List.filled(150, 22));
          expect(
            downloads().single.uri.queryParameters['device_id'],
            serverVersion == '4.9.0' ? 'device-1' : null,
          );
        },
      );

      test(
        '$serverVersion default pull prefers freegosy over newer other slots',
        () async {
          version = serverVersion;
          cloudSaves[1]['created_at'] = '2025-01-03T00:00:00Z';
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(downloads().single.uri.path, '/api/saves/1/content');
          expect(await localSave.readAsBytes(), List.filled(150, 11));
        },
      );

      test(
        '$serverVersion changing slots bypasses upload hash dedup',
        () async {
          version = serverVersion;
          cloudSaves.removeWhere((s) => s['slot'] == 'autosave');
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads(), hasLength(1));
          romm.updateConfig(config('autosave'));
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads().map((r) => r.queryParameters['slot']), [
            'freegosy',
            'autosave',
          ]);
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads(), hasLength(2));
          expect(
            requests.where((r) => r.uri.path == '/api/saves/delete'),
            isEmpty,
          );
        },
      );

      test(
        '$serverVersion changing slots bypasses pull cooldown and freshness cache',
        () async {
          version = serverVersion;
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(await sync.pullSave(game, romPath), isFalse);
          romm.updateConfig(config('autosave'));
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(downloads().map((r) => r.uri.path), [
            '/api/saves/1/content',
            '/api/saves/2/content',
          ]);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );

      for (final recreateService in [false, true]) {
        test(
          '$serverVersion restores A → B → A (recreate=$recreateService)',
          () async {
            version = serverVersion;
            expect(await sync.pullSave(game, romPath), isTrue);
            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
            expect(await sync.pullSave(game, romPath), isTrue);
            expect(await localSave.readAsBytes(), List.filled(150, 22));

            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
            if (recreateService) {
              sync = reloadSync();
            }
            expect(await sync.pullSave(game, romPath), isTrue);
            expect(await localSave.readAsBytes(), List.filled(150, 11));
            expect(downloads().map((r) => r.uri.path), [
              '/api/saves/1/content',
              '/api/saves/2/content',
              '/api/saves/1/content',
            ]);
            expect(await sync.pullSave(game, romPath), isFalse);
          },
        );
      }

      test(
        '$serverVersion keeps the same-lineage freshness shortcut after reload',
        () async {
          version = serverVersion;
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(await sync.pullSave(game, romPath), isTrue);
          sync = reloadSync();
          expect(await sync.pullSave(game, romPath), isFalse);
          expect(downloads(), hasLength(1));
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );

      test('$serverVersion manual restores record the actual slot', () async {
        version = serverVersion;
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
        expect(await sync.pullSave(game, romPath), isTrue);
        expect(
          await sync.pullSave(game, romPath, saveData: cloudSaves.first),
          isTrue,
        );
        expect(await localSave.readAsBytes(), List.filled(150, 11));
        sync = reloadSync();
        expect(await sync.pullSave(game, romPath), isTrue);
        expect(await localSave.readAsBytes(), List.filled(150, 22));
      });

      test('$serverVersion fallback restores record the actual slot', () async {
        version = serverVersion;
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'custom');
        expect(await sync.pullSave(game, romPath), isTrue);
        sync = reloadSync();
        expect(await sync.pullSave(game, romPath), isFalse);
        expect(downloads(), hasLength(1));
      });

      test(
        '$serverVersion retained clients read a changed persisted setting',
        () async {
          version = serverVersion;
          final retainedClient = romm;
          final retainedSync = sync;
          await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          expect(retainedClient.config.saveSlot, 'freegosy');
          expect(retainedClient.saveSlot, 'autosave');
          expect(
            (await retainedClient.uploadSave(game.id, localSave)).ok,
            isTrue,
          );
          expect((await retainedClient.getLatestSave(game.id))?['id'], 2);
          expect(
            await retainedSync.pushSaves(game, romPath, force: true),
            isTrue,
          );
          expect(uploads().map((r) => r.queryParameters['slot']), [
            'autosave',
            'autosave',
          ]);
          expect(await retainedSync.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );

      test(
        '$serverVersion push snapshots its slot before awaiting network work',
        () async {
          version = serverVersion;
          cloudSaves.removeWhere((s) => s['slot'] == 'autosave');
          beforeResponse = (options) async {
            if (options.uri.path == '/api/heartbeat') {
              await prefs.setString(
                RomMConfig.saveSlotPreferenceKey,
                'autosave',
              );
            }
          };
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads().single.queryParameters['slot'], 'freegosy');
          expect(prefs.getString('last_hash_42_game.sav'), isNotNull);
          expect(
            prefs.getString('last_hash_slot_autosave:42:game.sav'),
            isNull,
          );
          expect(await sync.pushSaves(game, romPath), isTrue);
          expect(uploads().last.queryParameters['slot'], 'autosave');
        },
      );

      test(
        '$serverVersion pull snapshots its selection and cache slot',
        () async {
          version = serverVersion;
          beforeResponse = (options) async {
            if (options.uri.path == '/api/heartbeat') {
              await prefs.setString(
                RomMConfig.saveSlotPreferenceKey,
                'autosave',
              );
            }
          };
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 11));
          if (serverVersion == '4.8.1') {
            expect(prefs.getString('last_pull_42'), isNotNull);
            expect(prefs.getString('last_pull_slot_autosave:42'), isNull);
          }
          expect(await sync.pullSave(game, romPath), isTrue);
          expect(await localSave.readAsBytes(), List.filled(150, 22));
        },
      );
    }

    test(
      'different games remain independent while one upload is pending',
      () async {
        final uploadStarted = Completer<void>();
        final finishUpload = Completer<void>();
        beforeResponse = (options) async {
          if (options.uri.path == '/api/saves' &&
              options.method == 'POST' &&
              options.queryParameters['rom_id'] == game.id) {
            if (!uploadStarted.isCompleted) uploadStarted.complete();
            await finishUpload.future;
          }
        };
        final push = sync.pushSaves(game, romPath);
        addTearDown(() async {
          if (!finishUpload.isCompleted) finishUpload.complete();
          await push;
        });
        await uploadStarted.future.timeout(const Duration(seconds: 5));
        final otherGame = Game(
          id: '43',
          name: 'game',
          platformSlug: 'gba',
          fileSize: 0,
        );
        expect(
          await reloadSync()
              .pushSaves(otherGame, romPath)
              .timeout(const Duration(seconds: 5)),
          isTrue,
        );
        finishUpload.complete();
        expect(await push, isTrue);
      },
    );

    test(
      'an already-current device still restores a newly selected lineage',
      () async {
        syncedSaveIds.add(2);
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
        expect(await sync.pullSave(game, romPath), isTrue);
        expect(await localSave.readAsBytes(), List.filled(150, 22));
      },
    );

    test(
      'a failed download does not record the requested lineage as installed',
      () async {
        expect(await sync.pullSave(game, romPath), isTrue);
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
        cloudSaves[1]['download_path'] = null;
        expect(await sync.pullSave(game, romPath), isFalse);
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'freegosy');
        sync = reloadSync();
        expect(await sync.pullSave(game, romPath), isFalse);
        expect(await localSave.readAsBytes(), List.filled(150, 11));
        expect(downloads(), hasLength(1));
      },
    );

    test(
      'implicit API selection snapshots preferences before awaiting the list',
      () async {
        beforeResponse = (options) async {
          if (options.uri.path == '/api/saves') {
            await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
          }
        };
        expect((await romm.getLatestSave(game.id))?['id'], 1);
        expect((await romm.getLatestSave(game.id))?['id'], 2);
      },
    );

    test(
      'empty configured slot falls back to the newest save across slots',
      () async {
        romm.updateConfig(config('custom'));
        expect((await romm.getLatestSave(game.id))?['id'], 1);
        cloudSaves.clear();
        expect(await romm.getLatestSave(game.id), isNull);
      },
    );

    test('selects the newest version within the configured slot', () async {
      cloudSaves.add({
        'id': 3,
        'slot': 'autosave',
        'created_at': '2025-01-01T12:00:00Z',
      });
      romm.updateConfig(config('autosave'));
      expect((await romm.getLatestSave(game.id))?['id'], 3);
    });

    test('fallback still detects historical saves without a slot', () async {
      cloudSaves.removeLast();
      cloudSaves.first.remove('slot');
      romm.updateConfig(config('autosave'));
      expect(await sync.pullSave(game, romPath), isTrue);
      expect(downloads().single.uri.path, '/api/saves/1/content');
    });

    test('existing default-slot hash cache remains effective', () async {
      cloudSaves.removeWhere((s) => s['slot'] == 'autosave');
      expect(await sync.pushSaves(game, romPath), isTrue);
      expect(prefs.getString('last_hash_42_game.sav'), isNotNull);
      romm.updateConfig(config('autosave'));
      expect(await sync.pushSaves(game, romPath), isTrue);
      await sync.clearHashCache(game.id);
      expect(await sync.pushSaves(game, romPath), isTrue);
      romm.updateConfig(config());
      expect(await sync.pushSaves(game, romPath), isTrue);
      expect(uploads().map((r) => r.queryParameters['slot']), [
        'freegosy',
        'autosave',
        'autosave',
      ]);
    });

    test(
      'legacy conflict check uses the configured slot instead of a newer other slot',
      () async {
        version = '4.8.1';
        romm.updateConfig(config('autosave'));
        expect(await sync.pullSave(game, romPath), isTrue);
        await prefs.setString(
          'last_pull_slot_autosave:42',
          '2025-01-01T12:00:00Z',
        );
        expect(await sync.pushSaves(game, romPath), isTrue);
        expect(uploads().single.queryParameters['slot'], 'autosave');
      },
    );

    test('manual pull and save picker retain access to other slots', () async {
      romm.updateConfig(config('autosave'));
      expect(await sync.getSavesForGame(game.id), hasLength(2));
      expect(
        await sync.pullSave(game, romPath, saveData: cloudSaves.first),
        isTrue,
      );
      expect(downloads().single.uri.path, '/api/saves/1/content');
    });

    test(
      'uploads without an explicit slot use config (including offline backups)',
      () async {
        romm.updateConfig(config('autosave'));
        expect((await romm.uploadSave(game.id, localSave)).ok, isTrue);
        expect(uploads().single.queryParameters['slot'], 'autosave');
        expect(
          (await romm.uploadSave(game.id, localSave, slot: 'custom')).ok,
          isTrue,
        );
        expect(uploads().last.queryParameters['slot'], 'custom');
      },
    );

    test(
      'pruning leaves freegosy saves intact when autosave is configured',
      () async {
        cloudSaves = List.generate(
          14,
          (i) => {
            'id': i,
            'slot': i < 7 ? 'autosave' : 'freegosy',
            'created_at': DateTime.utc(2025, 1, i + 1).toIso8601String(),
          },
        );
        romm.updateConfig(config('autosave'));
        await romm.pruneOldSaves(game.id);
        final deletion = requests.singleWhere(
          (r) => r.uri.path == '/api/saves/delete',
        );
        expect(deletion.data, {
          'saves': [1, 0],
        });
      },
    );

    test(
      'pruning keeps a recently overwritten record in the configured slot',
      () async {
        cloudSaves = List.generate(
          7,
          (i) => {
            'id': i,
            'slot': 'autosave',
            'created_at': DateTime.utc(2025, 1, i + 1).toIso8601String(),
          },
        );
        cloudSaves.first['updated_at'] = '2026-01-01T00:00:00Z';
        await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
        await romm.pruneOldSaves(game.id);
        final deletion = requests.singleWhere(
          (r) => r.uri.path == '/api/saves/delete',
        );
        expect(deletion.data, {
          'saves': [2, 1],
        });
      },
    );
  });
}
