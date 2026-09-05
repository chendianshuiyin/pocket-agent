// ignore_for_file: use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef MockRequestHandler = FutureOr<void> Function(MockRpcMessage message);

final class MockRpcMessage {
  const MockRpcMessage(this.socket, this.value, this.connectionNumber);

  final WebSocket socket;
  final Map<String, Object?> value;
  final int connectionNumber;

  void result(Object? result) => socket.add(
    jsonEncode(<String, Object?>{'id': value['id'], 'result': result}),
  );

  void error(int code, String message, {Object? data}) => socket.add(
    jsonEncode(<String, Object?>{
      'id': value['id'],
      'error': <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    }),
  );
}

final class MockAppServer {
  MockAppServer._(this._server);

  static Future<MockAppServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = MockAppServer._(server);
    server.listen(mock._accept);
    return mock;
  }

  final HttpServer _server;
  final List<MockRpcMessage> received = <MockRpcMessage>[];
  final List<WebSocket> sockets = <WebSocket>[];
  MockRequestHandler? handler;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/app-server');
  int get connectionCount => sockets.length;
  WebSocket get latestSocket => sockets.last;

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    final connectionNumber = sockets.length;
    socket.listen((frame) async {
      final value = (jsonDecode(frame as String) as Map).map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
      final message = MockRpcMessage(socket, value, connectionNumber);
      received.add(message);
      if (value['method'] == 'initialize') {
        message.result(<String, Object?>{
          'userAgent': 'mock-app-server',
          'platformFamily': 'unix',
          'platformOs': 'linux',
          'codexHome': '/tmp/codex',
        });
        return;
      }
      await handler?.call(message);
    });
  }

  void notify(String method, Map<String, Object?> params) {
    latestSocket.add(
      jsonEncode(<String, Object?>{'method': method, 'params': params}),
    );
  }

  void request(Object id, String method, Map<String, Object?> params) {
    latestSocket.add(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  Future<List<MockRpcMessage>> waitFor(
    String method, {
    int count = 1,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final matches = received
          .where((message) => message.value['method'] == method)
          .toList();
      if (matches.length >= count) return matches;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('Did not receive $count $method messages');
  }

  Future<void> closeConnections([
    int code = 4001,
    String reason = 'restart',
  ]) async {
    for (final socket in List<WebSocket>.from(sockets)) {
      if (socket.readyState == WebSocket.open) await socket.close(code, reason);
    }
  }

  Future<void> close() async {
    await closeConnections(WebSocketStatus.normalClosure, 'test complete');
    await _server.close(force: true);
  }
}
