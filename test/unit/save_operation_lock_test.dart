import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/save_operation_lock.dart';

void main() {
  test('same-game operations wait in order', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final events = <int>[];
    final first = SaveOperationLock.run('42', (_) async {
      events.add(1);
      entered.complete();
      await release.future;
      events.add(2);
    });
    await entered.future;
    final second = SaveOperationLock.run('42', (_) async => events.add(3));
    await Future<void>.delayed(Duration.zero);
    expect(events, [1]);
    release.complete();
    await Future.wait([first, second]);
    expect(events, [1, 2, 3]);
  });

  test('different games remain independent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = SaveOperationLock.run('42', (_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      expect(
        await SaveOperationLock.run(
          '43',
          (_) async => 7,
        ).timeout(const Duration(seconds: 1)),
        7,
      );
    } finally {
      release.complete();
      await first;
    }
  });

  test('an explicit nested lease reuses the hold', () async {
    expect(
      await SaveOperationLock.run(
        '42',
        (lease) async =>
            SaveOperationLock.run('42', (_) async => 7, lease: lease),
      ).timeout(const Duration(seconds: 1)),
      7,
    );
  });

  test('a lease cannot be reused for another game', () async {
    await SaveOperationLock.run('42', (lease) async {
      await expectLater(
        SaveOperationLock.run('43', (_) async => 7, lease: lease),
        throwsStateError,
      );
      expect(
        await SaveOperationLock.run('42', (_) async => 8, lease: lease),
        8,
      );
    });
  });

  test('independent work started inside a hold still queues', () async {
    final events = <String>[];
    late Future<void> queued;
    await SaveOperationLock.run('42', (_) async {
      events.add('owner');
      queued = SaveOperationLock.run('42', (_) async => events.add('queued'));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['owner']);
    });
    await queued;
    expect(events, ['owner', 'queued']);
  });

  test('errors release the hold and expired leases cannot bypass it', () async {
    late SaveOperationLease expired;
    await expectLater(
      SaveOperationLock.run<void>('42', (lease) async {
        expired = lease;
        throw StateError('failed');
      }),
      throwsStateError,
    );
    await expectLater(
      SaveOperationLock.run('42', (_) async => 7, lease: expired),
      throwsStateError,
    );
    expect(await SaveOperationLock.run('42', (_) async => 8), 8);
  });
}
