import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Serializes every write-side operation performed on an SSH socket.
///
/// In particular, a native [Socket.flush] may temporarily bind its sink. SSH
/// packets that arrive during that flush must remain queued until it finishes.
class QueuedSSHSocket implements SSHSocket {
  QueuedSSHSocket(this._delegate) {
    _sink = _QueuedStreamSink(this);
  }

  final SSHSocket _delegate;
  final Queue<_WriteOperation> _operations = Queue<_WriteOperation>();
  late final _QueuedStreamSink _sink;
  Completer<void>? _activeOperationAbort;
  Future<void>? _closeFuture;
  Object? _failure;
  StackTrace? _failureStackTrace;
  bool _draining = false;
  bool _closing = false;
  bool _destroyed = false;
  bool _closedNormally = false;

  @override
  Stream<Uint8List> get stream => _delegate.stream;

  @override
  StreamSink<List<int>> get sink => _sink;

  @override
  Future<void> get done => _delegate.done;

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    return _closeFuture = _closeGracefully();
  }

  Future<void> _closeGracefully() async {
    try {
      await _sink.sealAndWait();
      if (_destroyed) {
        _throwFailureIfPresent();
        return;
      }
      await _enqueueObserved(() => _delegate.close());
      _closedNormally = true;
    } on _SocketDestroyedException {
      _throwFailureIfPresent();
    }
  }

  @override
  void destroy() {
    if (_destroyed || _closedNormally) return;
    _destroyed = true;
    _sink.abort();
    _abortActiveOperation();
    _failQueued(const _SocketDestroyedException());
    _delegate.destroy();
  }

  @override
  Future<void> flush() {
    _ensureOperationAllowed();
    final pendingStream = _sink.pendingStream;
    if (pendingStream == null) {
      return _enqueueObserved(() => _delegate.flush());
    }
    return pendingStream.then((_) {
      _ensureOperationAllowed();
      return _enqueueObserved(() => _delegate.flush());
    });
  }

  void _add(List<int> data) {
    _ensureOperationAllowed();
    final packet = Uint8List.fromList(data);
    _enqueueUnobserved(() async => _delegate.sink.add(packet));
  }

  void _addError(Object error, StackTrace? stackTrace) {
    _ensureOperationAllowed();
    _enqueueUnobserved(() async => _delegate.sink.addError(error, stackTrace));
  }

  Future<void> _addObserved(List<int> data) {
    _ensureOperationAllowed(allowClosing: true);
    final packet = Uint8List.fromList(data);
    return _enqueueObserved(() async => _delegate.sink.add(packet));
  }

  Future<void> _addErrorObserved(Object error, StackTrace stackTrace) {
    _ensureOperationAllowed(allowClosing: true);
    return _enqueueObserved(
      () async => _delegate.sink.addError(error, stackTrace),
    );
  }

  void _enqueueUnobserved(Future<void> Function() action) {
    _operations.add(_WriteOperation(action));
    _startDraining();
  }

  Future<void> _enqueueObserved(Future<void> Function() action) {
    final completion = Completer<void>();
    _operations.add(_WriteOperation(action, completion: completion));
    _startDraining();
    return completion.future;
  }

  void _startDraining() {
    if (_draining) return;
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (!_destroyed && _operations.isNotEmpty) {
      final operation = _operations.removeFirst();
      final abort = Completer<void>();
      _activeOperationAbort = abort;
      try {
        await _runUntilAborted(operation.action(), abort.future);
        operation.complete();
      } catch (error, stackTrace) {
        operation.completeError(error, stackTrace);
        if (error is! _SocketDestroyedException) {
          _failTransport(error, stackTrace);
        }
        break;
      } finally {
        if (identical(_activeOperationAbort, abort)) {
          _activeOperationAbort = null;
        }
      }
    }
    _draining = false;
    if (!_destroyed && _operations.isNotEmpty) _startDraining();
  }

  Future<void> _runUntilAborted(Future<void> action, Future<void> abort) async {
    final outcome = await Future.any<_OperationOutcome>([
      action.then<_OperationOutcome>(
        (_) => const _OperationOutcome.completed(),
        onError: (Object error, StackTrace stackTrace) =>
            _OperationOutcome.failed(error, stackTrace),
      ),
      abort.then<_OperationOutcome>((_) => const _OperationOutcome.destroyed()),
    ]);
    if (outcome.destroyed) throw const _SocketDestroyedException();
    final error = outcome.error;
    if (error != null) {
      Error.throwWithStackTrace(error, outcome.stackTrace!);
    }
  }

  void _failTransport(Object error, StackTrace stackTrace) {
    _failure ??= error;
    _failureStackTrace ??= stackTrace;
    _destroyed = true;
    _sink.abort(error: error, stackTrace: stackTrace);
    _abortActiveOperation();
    _failQueued(error, stackTrace);
    _delegate.destroy();
  }

  void _failQueued(Object error, [StackTrace? stackTrace]) {
    while (_operations.isNotEmpty) {
      _operations.removeFirst().completeError(error, stackTrace);
    }
  }

  void _abortActiveOperation() {
    final abort = _activeOperationAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _ensureOperationAllowed({bool allowClosing = false}) {
    _throwFailureIfPresent();
    if (_destroyed) throw StateError('SSH socket is destroyed');
    if (_closedNormally || (_closing && !allowClosing)) {
      throw StateError('SSH socket is closed');
    }
  }

  void _throwFailureIfPresent() {
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure, _failureStackTrace!);
    }
  }
}

class _QueuedStreamSink implements StreamSink<List<int>> {
  _QueuedStreamSink(this._owner);

  final QueuedSSHSocket _owner;
  Future<void>? _pendingStream;
  _StreamAbortSignal? _streamAbort;
  bool _sealed = false;

  @override
  void add(List<int> data) {
    _ensureWritable();
    _owner._add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _ensureWritable();
    _owner._addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _ensureWritable();
    if (_pendingStream != null) {
      throw StateError('StreamSink is bound to a stream');
    }
    final abort = _StreamAbortSignal();
    _streamAbort = abort;
    late final Future<void> pending;
    pending = _pump(stream, abort).whenComplete(() {
      if (identical(_pendingStream, pending)) {
        _pendingStream = null;
        _streamAbort = null;
      }
    });
    _pendingStream = pending;
    return pending;
  }

  Future<void> _pump(Stream<List<int>> stream, _StreamAbortSignal abort) async {
    final iterator = StreamIterator<List<int>>(stream);
    try {
      while (true) {
        final abortWatch = abort.watch();
        late final _StreamStep next;
        try {
          next = await Future.any<_StreamStep>([
            iterator.moveNext().then<_StreamStep>(
              (hasNext) => _StreamStep.next(hasNext),
              onError: (Object error, StackTrace stackTrace) =>
                  _StreamStep.failed(error, stackTrace),
            ),
            abortWatch.future.then<_StreamStep>(_StreamStep.aborted),
          ]);
        } finally {
          abortWatch.detach();
        }
        final aborted = next.abort;
        if (aborted != null) {
          final error = aborted.error;
          if (error != null) {
            Error.throwWithStackTrace(error, aborted.stackTrace!);
          }
          return;
        }
        final error = next.error;
        if (error != null) {
          await _owner._addErrorObserved(error, next.stackTrace!);
          Error.throwWithStackTrace(error, next.stackTrace!);
        }
        if (!next.hasNext) return;
        await _owner._addObserved(iterator.current);
      }
    } finally {
      unawaited(iterator.cancel());
    }
  }

  @override
  Future<void> close() => _owner.close();

  @override
  Future<void> get done => _owner.done;

  Future<void> sealAndWait() async {
    _sealed = true;
    await waitForPendingStream();
  }

  Future<void> waitForPendingStream() => _pendingStream ?? Future<void>.value();

  Future<void>? get pendingStream => _pendingStream;

  void abort({Object? error, StackTrace? stackTrace}) {
    _sealed = true;
    final abort = _streamAbort;
    abort?.abort(_StreamAbort(error, stackTrace));
  }

  void _ensureWritable() {
    if (_sealed) throw StateError('StreamSink is closed');
    if (_pendingStream != null) {
      throw StateError('StreamSink is bound to a stream');
    }
  }
}

class _WriteOperation {
  const _WriteOperation(this.action, {this.completion});

  final Future<void> Function() action;
  final Completer<void>? completion;

  void complete() {
    final target = completion;
    if (target != null && !target.isCompleted) target.complete();
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    final target = completion;
    if (target != null && !target.isCompleted) {
      target.completeError(error, stackTrace);
    }
  }
}

class _OperationOutcome {
  const _OperationOutcome.completed()
    : destroyed = false,
      error = null,
      stackTrace = null;

  const _OperationOutcome.destroyed()
    : destroyed = true,
      error = null,
      stackTrace = null;

  const _OperationOutcome.failed(this.error, this.stackTrace)
    : destroyed = false;

  final bool destroyed;
  final Object? error;
  final StackTrace? stackTrace;
}

class _StreamStep {
  const _StreamStep.next(this.hasNext)
    : abort = null,
      error = null,
      stackTrace = null;

  const _StreamStep.failed(this.error, this.stackTrace)
    : hasNext = false,
      abort = null;

  const _StreamStep.aborted(this.abort)
    : hasNext = false,
      error = null,
      stackTrace = null;

  final bool hasNext;
  final _StreamAbort? abort;
  final Object? error;
  final StackTrace? stackTrace;
}

class _StreamAbort {
  const _StreamAbort(this.error, this.stackTrace);

  final Object? error;
  final StackTrace? stackTrace;
}

class _StreamAbortSignal {
  _StreamAbort? _result;
  _StreamAbortWatch? _watch;

  _StreamAbortWatch watch() {
    final result = _result;
    if (result != null) return _StreamAbortWatch.completed(result);
    final watch = _StreamAbortWatch(this);
    _watch = watch;
    return watch;
  }

  void abort(_StreamAbort result) {
    if (_result != null) return;
    _result = result;
    final watch = _watch;
    _watch = null;
    watch?.complete(result);
  }

  void detach(_StreamAbortWatch watch) {
    if (identical(_watch, watch)) _watch = null;
  }
}

class _StreamAbortWatch {
  _StreamAbortWatch(this._signal) : _completer = Completer<_StreamAbort>();

  _StreamAbortWatch.completed(_StreamAbort result)
    : _signal = null,
      _completer = Completer<_StreamAbort>()..complete(result);

  final _StreamAbortSignal? _signal;
  final Completer<_StreamAbort> _completer;

  Future<_StreamAbort> get future => _completer.future;

  void complete(_StreamAbort result) {
    if (!_completer.isCompleted) _completer.complete(result);
  }

  void detach() => _signal?.detach(this);
}

class _SocketDestroyedException implements Exception {
  const _SocketDestroyedException();
}
