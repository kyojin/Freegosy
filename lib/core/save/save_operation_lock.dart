import 'dart:async';

/// Serializes save operations for a game across services, including retries.
/// Awaited nested operations may reuse a hold only with its explicit lease.
abstract final class SaveOperationLock {
  static final Map<String, Future<void>> _pending = {};

  static Future<T> run<T>(
    String gameId,
    Future<T> Function(SaveOperationLease lease) body, {
    SaveOperationLease? lease,
  }) async {
    if (lease != null) {
      if (!lease._active || lease._gameId != gameId) {
        throw StateError(
          'The save-operation lease is inactive or belongs to another game.',
        );
      }
      return body(lease);
    }

    final previous = _pending[gameId] ?? Future<void>.value();
    final finished = Completer<void>();
    final tail = finished.future;
    _pending[gameId] = tail;
    await previous;
    final acquired = SaveOperationLease._(gameId);
    try {
      return await body(acquired);
    } finally {
      acquired._active = false;
      finished.complete();
      if (identical(_pending[gameId], tail)) _pending.remove(gameId);
    }
  }
}

final class SaveOperationLease {
  SaveOperationLease._(this._gameId);
  final String _gameId;
  bool _active = true;
}
