import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_connection.dart';

class CodexTunnel {
  CodexTunnel._(this._server, this._connection, this.remotePort) {
    _serverSubscription = _server.listen(_accept);
  }

  final ServerSocket _server;
  final SshTransport _connection;
  final int remotePort;
  final Set<_TunnelPair> _pairs = {};
  late final StreamSubscription<Socket> _serverSubscription;
  bool _closed = false;
  String? _lastFailureType;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');
  int get localPort => _server.port;
  bool get isClosed => _closed;
  String? get lastFailureType => _lastFailureType;

  static Future<CodexTunnel> open(
    SshTransport connection,
    int remotePort,
  ) async {
    if (!connection.isConnected) {
      throw StateError('SSH connection is not connected');
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return CodexTunnel._(server, connection, remotePort);
  }

  void _accept(Socket local) {
    unawaited(_connect(local));
  }

  Future<void> _connect(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    try {
      final remote = await _connection.forwardLoopback(remotePort);
      if (_closed) {
        local.destroy();
        remote.destroy();
        return;
      }
      late final _TunnelPair pair;
      pair = _TunnelPair(
        local,
        remote,
        onClosed: () => _pairs.remove(pair),
        onFailure: (type) => _lastFailureType = type,
      );
      _pairs.add(pair);
      pair.start();
    } catch (error) {
      _lastFailureType = 'connect:${error.runtimeType}';
      local.destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _serverSubscription.cancel();
    await _server.close();
    final pairs = _pairs.toList(growable: false);
    await Future.wait(pairs.map((pair) => pair.close()));
    _pairs.clear();
  }
}

class _TunnelPair {
  _TunnelPair(
    this.local,
    this.remote, {
    required this.onClosed,
    required this.onFailure,
  });

  final Socket local;
  final SSHForwardChannel remote;
  final void Function() onClosed;
  final void Function(String type) onFailure;
  bool _closed = false;

  void start() {
    unawaited(_pump());
  }

  Future<void> _pump() async {
    var completedNormally = false;
    try {
      await pumpBidirectionalStreams(
        leftInput: local,
        leftOutput: local,
        rightInput: remote.stream,
        rightOutput: remote.sink,
      );
      await remote.flush();
      completedNormally = true;
    } catch (error) {
      onFailure(error.runtimeType.toString());
      // Closing either endpoint below also terminates the opposite pump.
    } finally {
      if (completedNormally) {
        _finish();
      } else {
        await close();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    local.destroy();
    remote.destroy();
    onClosed();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    onClosed();
  }
}

Future<void> pumpBidirectionalStreams({
  required Stream<List<int>> leftInput,
  required StreamSink<List<int>> leftOutput,
  required Stream<List<int>> rightInput,
  required StreamSink<List<int>> rightOutput,
}) async {
  await Future.wait<void>([
    leftInput.map<List<int>>((chunk) => chunk).pipe(rightOutput),
    rightInput.map<List<int>>((chunk) => chunk).pipe(leftOutput),
  ], eagerError: true);
}
