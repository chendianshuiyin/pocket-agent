import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_connection.dart';

class CodexTunnel {
  CodexTunnel._(
    this._server,
    this._connection,
    this.remotePort,
    this._capabilityToken,
  ) {
    _serverSubscription = _server.listen(_accept);
  }

  final ServerSocket _server;
  final SshTransport _connection;
  final int remotePort;
  final String? _capabilityToken;
  final Set<_TunnelPair> _pairs = {};
  late final StreamSubscription<Socket> _serverSubscription;
  bool _closed = false;
  String? _lastFailureType;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');
  int get localPort => _server.port;
  bool get isClosed => _closed;
  String? get lastFailureType => _lastFailureType;

  /// WebSocket app-server transport capability, not a Codex account credential.
  Map<String, String> get clientHeaders {
    final token = _capabilityToken;
    if (token == null) return const <String, String>{};
    return Map<String, String>.unmodifiable(<String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $token',
    });
  }

  static Future<CodexTunnel> open(
    SshTransport connection,
    int remotePort, {
    String? capabilityToken,
  }) async {
    if (!connection.isConnected) {
      throw StateError('SSH connection is not connected');
    }
    if (capabilityToken != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(capabilityToken)) {
      throw ArgumentError('Invalid runtime capability token');
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return CodexTunnel._(server, connection, remotePort, capabilityToken);
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

Future<bool> verifyWebSocketCapabilityAuthentication(
  Uri uri,
  Map<String, String> authenticatedHeaders, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final authorization = authenticatedHeaders[HttpHeaders.authorizationHeader];
  if (authorization == null || !authorization.startsWith('Bearer ')) {
    return false;
  }
  if (!await _httpUpgradeAuthenticationRejected(uri, const {}, timeout)) {
    return false;
  }
  if (!await _httpUpgradeAuthenticationRejected(uri, const {
    HttpHeaders.authorizationHeader: 'Bearer invalid-capability-token',
  }, timeout)) {
    return false;
  }

  WebSocket? socket;
  var timedOut = false;
  final connection = WebSocket.connect(
    uri.toString(),
    headers: authenticatedHeaders,
  );
  connection.then<void>((lateSocket) {
    if (timedOut) unawaited(_closeWebSocket(lateSocket, timeout));
  }, onError: (Object _, StackTrace _) {});
  try {
    socket = await connection.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        throw TimeoutException('WebSocket authentication timed out');
      },
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    if (socket != null) await _closeWebSocket(socket, timeout);
  }
}

Future<bool> _httpUpgradeAuthenticationRejected(
  Uri uri,
  Map<String, String> headers,
  Duration timeout,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'))
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', 'AAAAAAAAAAAAAAAAAAAAAA==');
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    return response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<void> _closeWebSocket(WebSocket socket, Duration timeout) async {
  try {
    await socket.close().timeout(timeout);
  } catch (_) {}
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
