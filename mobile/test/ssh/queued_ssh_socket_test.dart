import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/ssh/queued_ssh_socket.dart';

void main() {
  test('native Socket rejects a packet added during flush', () async {
    final pair = await SocketPair.open();
    try {
      pair.client.add([1]);
      final flushing = pair.client.flush();

      expect(() => pair.client.add([2]), throwsStateError);
      await flushing;
    } finally {
      await pair.close();
    }
  });

  test('real Socket queues a packet until an active flush finishes', () async {
    final pair = await SocketPair.open();
    final delegate = TrackingIoSSHSocket(pair.client);
    final socket = QueuedSSHSocket(delegate);
    final received = <int>[];
    final receivedAll = Completer<void>();
    final subscription = pair.server.listen((data) {
      received.addAll(data);
      if (received.length >= 4 && !receivedAll.isCompleted) {
        receivedAll.complete();
      }
    });
    try {
      socket.sink.add([1, 2]);
      final flushing = socket.flush();
      socket.sink.add([3, 4]);

      await delegate.flushStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(delegate.sinkImpl.addCalls, 1);

      delegate.releaseFlush.complete();
      await flushing;
      await socket.flush();
      await receivedAll.future.timeout(const Duration(seconds: 2));
      expect(received, [1, 2, 3, 4]);
      expect(delegate.sinkImpl.addCalls, 2);
    } finally {
      socket.destroy();
      await subscription.cancel();
      await pair.close();
    }
  });

  test('copies a packet before a queued native write begins', () async {
    final delegate = FakeSSHSocket()..flushBarrier = Completer<void>();
    final socket = QueuedSSHSocket(delegate);
    final blockingFlush = socket.flush();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.flushCalls, 1);

    final packet = Uint8List.fromList([1, 2, 3]);
    socket.sink.add(packet);
    packet[0] = 9;

    delegate.flushBarrier!.complete();
    await blockingFlush;
    await socket.flush();
    expect(delegate.sinkImpl.values, [1, 2, 3]);
  });

  test(
    'destroy races only the active writer and drops queued writes',
    () async {
      final delegate = FakeSSHSocket()..flushBarrier = Completer<void>();
      final socket = QueuedSSHSocket(delegate);
      final blockingFlush = socket.flush();
      await Future<void>.delayed(Duration.zero);

      for (var value = 0; value < 100; value += 1) {
        socket.sink.add([value]);
      }
      socket.destroy();

      await expectLater(blockingFlush, throwsA(isA<Exception>()));
      expect(delegate.destroyCalls, 1);
      expect(delegate.sinkImpl.values, isEmpty);
    },
  );

  test('destroy still reaches delegate while close is blocked', () async {
    final delegate = FakeSSHSocket()..closeBarrier = Completer<void>();
    final socket = QueuedSSHSocket(delegate);

    final closing = socket.close();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.closeCalls, 1);

    socket.destroy();
    expect(delegate.destroyCalls, 1);
    await closing;
  });

  test('destroy aborts a pending streamed write and unblocks close', () async {
    final delegate = FakeSSHSocket();
    final socket = QueuedSSHSocket(delegate);
    final source = StreamController<List<int>>();
    final adding = socket.sink.addStream(source.stream);
    source.add([1, 2, 3]);

    final closing = socket.close();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.closeCalls, 0);

    socket.destroy();
    await adding;
    await closing;
    expect(delegate.destroyCalls, 1);
    expect(delegate.closeCalls, 0);
    expect(delegate.sinkImpl.values, [1, 2, 3]);
    await source.close();
  });

  test('flush waits for a streamed write then flushes the delegate', () async {
    final delegate = FakeSSHSocket();
    final socket = QueuedSSHSocket(delegate);
    final source = StreamController<List<int>>();
    final adding = socket.sink.addStream(source.stream);
    source.add([4]);

    final flushing = socket.flush();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.flushCalls, 0);

    await source.close();
    await adding;
    await flushing;
    expect(delegate.flushCalls, 1);
    expect(delegate.sinkImpl.addStreamCalls, 0);
  });

  test('packet and flush failures propagate to the caller', () async {
    final delegate = FakeSSHSocket();
    final socket = QueuedSSHSocket(delegate);
    delegate.sinkImpl.addFailure = StateError('write failed');

    socket.sink.add([1]);
    await expectLater(socket.flush(), throwsStateError);

    final flushDelegate = FakeSSHSocket();
    final flushSocket = QueuedSSHSocket(flushDelegate);
    flushDelegate.flushFailure = StateError('flush failed');
    await expectLater(flushSocket.flush(), throwsStateError);
  });

  test('streamed write failures complete addStream with an error', () async {
    final delegate = FakeSSHSocket();
    final socket = QueuedSSHSocket(delegate);
    final source = StreamController<List<int>>();
    final adding = socket.sink.addStream(source.stream);
    delegate.sinkImpl.addFailure = StateError('write failed');

    source.add([1]);
    await expectLater(adding, throwsStateError);
    await source.close();
  });

  test('delegate close and done failures remain observable', () async {
    final closeDelegate = FakeSSHSocket()
      ..closeFailure = StateError('close failed');
    await expectLater(QueuedSSHSocket(closeDelegate).close(), throwsStateError);

    final doneDelegate = FakeSSHSocket();
    final socket = QueuedSSHSocket(doneDelegate);
    final observedDone = expectLater(socket.done, throwsStateError);
    doneDelegate.doneCompleter.completeError(StateError('socket failed'));
    await observedDone;
  });
}

class FakeSSHSocket implements SSHSocket {
  final StreamController<Uint8List> input = StreamController<Uint8List>();
  final RecordingSink sinkImpl = RecordingSink();
  final Completer<void> doneCompleter = Completer<void>();
  Completer<void>? closeBarrier;
  Completer<void>? flushBarrier;
  Object? closeFailure;
  Object? flushFailure;
  int closeCalls = 0;
  int destroyCalls = 0;
  int flushCalls = 0;

  @override
  Stream<Uint8List> get stream => input.stream;

  @override
  StreamSink<List<int>> get sink => sinkImpl;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Future<void> close() async {
    closeCalls += 1;
    await closeBarrier?.future;
    final failure = closeFailure;
    if (failure != null) throw failure;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  @override
  void destroy() {
    destroyCalls += 1;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  @override
  Future<void> flush() async {
    flushCalls += 1;
    await flushBarrier?.future;
    final failure = flushFailure;
    if (failure != null) throw failure;
  }
}

class RecordingSink implements StreamSink<List<int>> {
  final List<int> values = <int>[];
  final Completer<void> doneCompleter = Completer<void>();
  Object? addFailure;
  int addStreamCalls = 0;

  @override
  void add(List<int> data) {
    final failure = addFailure;
    if (failure != null) throw failure;
    values.addAll(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    addStreamCalls += 1;
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  @override
  Future<void> get done => doneCompleter.future;
}

class SocketPair {
  const SocketPair(this.client, this.server, this.listener);

  final Socket client;
  final Socket server;
  final ServerSocket listener;

  static Future<SocketPair> open() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    listener.listen(accepted.complete);
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
    );
    return SocketPair(client, await accepted.future, listener);
  }

  Future<void> close() async {
    client.destroy();
    server.destroy();
    await listener.close();
  }
}

class TrackingIoSSHSocket implements SSHSocket {
  TrackingIoSSHSocket(this.socket) : sinkImpl = TrackingSocketSink(socket);

  final Socket socket;
  final TrackingSocketSink sinkImpl;
  final Completer<void> flushStarted = Completer<void>();
  final Completer<void> releaseFlush = Completer<void>();
  bool _gatedFlush = false;

  @override
  Stream<Uint8List> get stream => socket;

  @override
  StreamSink<List<int>> get sink => sinkImpl;

  @override
  Future<void> get done => socket.done;

  @override
  Future<void> close() => socket.close();

  @override
  void destroy() => socket.destroy();

  @override
  Future<void> flush() async {
    final nativeFlush = socket.flush();
    if (!_gatedFlush) {
      _gatedFlush = true;
      flushStarted.complete();
      await releaseFlush.future;
    }
    await nativeFlush;
  }
}

class TrackingSocketSink implements StreamSink<List<int>> {
  TrackingSocketSink(this.socket);

  final Socket socket;
  int addCalls = 0;

  @override
  void add(List<int> data) {
    addCalls += 1;
    socket.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => socket.addStream(stream);

  @override
  Future<void> close() => socket.close();

  @override
  Future<void> get done => socket.done;
}
