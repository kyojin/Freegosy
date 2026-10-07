import 'dart:async';
import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/background_sync_queue.dart';
import 'package:freegosy/core/save/backup_entry.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/save_operation_lock.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

class _DeferredRomm extends RommService {
  _DeferredRomm(
    int port, {
    this.holdMetadata = false,
    this.holdUpload = false,
    this.uploadOk = true,
  }) : super(
         RomMConfig(
           baseUrl: 'http://127.0.0.1:$port',
           username: '',
           password: '',
         ),
         skipConnectivityCheck: true,
       );
  final bool holdMetadata;
  final bool holdUpload;
  final bool uploadOk;
  final selected = Completer<void>();
  final releaseMetadata = Completer<void>();
  final uploading = Completer<void>();
  final releaseUpload = Completer<void>();
  final events = <String>[];
  final uploadedPaths = <String>[];

  @override
  Future<Game?> getGame(String id) async {
    selected.complete();
    if (holdMetadata) await releaseMetadata.future;
    return Game(id: id, name: 'game', fileSize: 0);
  }

  @override
  Future<({bool ok, Map<String, dynamic>? conflict})> uploadSave(
    String gameId,
    io.File saveFile, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool autocleanup = false,
    int autocleanupLimit = 5,
    bool overwrite = false,
    io.File? screenshotFile,
    String? overrideFilename,
  }) async {
    events.add('retry started');
    uploading.complete();
    if (holdUpload) await releaseUpload.future;
    uploadedPaths.add(saveFile.path);
    events.add('retry finished');
    return (ok: uploadOk, conflict: null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory temp;
  late io.ServerSocket server;
  late StreamSubscription<io.Socket> subscription;
  late BackupRepository repo;
  late BackupEntry older;

  setUp(() async {
    temp = await io.Directory.systemTemp.createTemp('backup_queue_race_');
    Hive.init(temp.path);
    if (!Hive.isAdapterRegistered(1))
      Hive.registerAdapter(BackupEntryAdapter());
    await Hive.openBox<List>('freegosy_backups');
    repo = BackupRepository()..initBox();
    final file = await io.File(
      p.join(temp.path, 'older.zip'),
    ).writeAsString('older');
    older = BackupEntry(
      timestamp: DateTime(2025),
      md5Hash: 'older',
      localZipPath: file.path,
    );
    await repo.addEntry('42', older);
    server = await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((socket) => socket.destroy());
  });

  tearDown(() async {
    await subscription.cancel();
    await server.close();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test(
    'a failed retry preserves current and older pending checkpoints',
    () async {
      final file = await io.File(
        p.join(temp.path, 'newer.zip'),
      ).writeAsString('newer');
      await repo.addEntry(
        '42',
        BackupEntry(
          timestamp: DateTime(2026),
          md5Hash: 'newer',
          localZipPath: file.path,
        ),
      );
      final romm = _DeferredRomm(server.port, uploadOk: false);
      await BackgroundSyncQueue.processQueue(romm, repo);
      expect(romm.uploadedPaths, [file.path]);
      expect(repo.getUnsyncedEntries(), hasLength(2));
      romm.isOffline.dispose();
    },
  );

  test('another queue invocation cannot run during metadata lookup', () async {
    final romm = _DeferredRomm(server.port, holdMetadata: true);
    final first = BackgroundSyncQueue.processQueue(romm, repo);
    try {
      await romm.selected.future;
      await BackgroundSyncQueue.processQueue(romm, repo);
      await SaveOperationLock.run(
        '42',
        (_) async => repo.acknowledgeEntries('42', [older]),
      );
      romm.releaseMetadata.complete();
      await first;
      expect(romm.uploadedPaths, isEmpty);
    } finally {
      if (!romm.releaseMetadata.isCompleted) romm.releaseMetadata.complete();
      await first;
      romm.isOffline.dispose();
    }
  });

  test('retired retries are rechecked after metadata lookup', () async {
    final romm = _DeferredRomm(server.port, holdMetadata: true);
    final queue = BackgroundSyncQueue.processQueue(romm, repo);
    try {
      await romm.selected.future;
      await SaveOperationLock.run(
        '42',
        (_) async => repo.acknowledgeEntries('42', [older]),
      );
      romm.releaseMetadata.complete();
      await queue;
      expect(romm.uploadedPaths, isEmpty);
    } finally {
      if (!romm.releaseMetadata.isCompleted) romm.releaseMetadata.complete();
      await queue;
      romm.isOffline.dispose();
    }
  });

  test('an active retry finishes before a newer normal push', () async {
    final romm = _DeferredRomm(server.port, holdUpload: true);
    final queue = BackgroundSyncQueue.processQueue(romm, repo);
    try {
      await romm.uploading.future;
      final normal = SaveOperationLock.run(
        '42',
        (_) async => romm.events.add('normal push'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(romm.events, ['retry started']);
      romm.releaseUpload.complete();
      await normal;
      expect(romm.events, ['retry started', 'retry finished', 'normal push']);
      await queue;
      expect(repo.getUnsyncedEntries(), isEmpty);
    } finally {
      if (!romm.releaseUpload.isCompleted) romm.releaseUpload.complete();
      await queue;
      romm.isOffline.dispose();
    }
  });

  test(
    'queue selects a newer pending checkpoint added during metadata lookup',
    () async {
      final romm = _DeferredRomm(server.port, holdMetadata: true);
      final queue = BackgroundSyncQueue.processQueue(romm, repo);
      try {
        await romm.selected.future;
        final file = await io.File(
          p.join(temp.path, 'newer.zip'),
        ).writeAsString('newer');
        await repo.addEntry(
          '42',
          BackupEntry(
            timestamp: DateTime(2026),
            md5Hash: 'newer',
            localZipPath: file.path,
          ),
        );
        romm.releaseMetadata.complete();
        await queue;
        expect(romm.uploadedPaths, [file.path]);
        expect(repo.getUnsyncedEntries(), isEmpty);
      } finally {
        if (!romm.releaseMetadata.isCompleted) romm.releaseMetadata.complete();
        await queue;
        romm.isOffline.dispose();
      }
    },
  );
}
