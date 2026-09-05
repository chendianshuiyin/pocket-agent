import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

const fakeToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  test('bidirectional pump preserves final chunks before EOF', () async {
    final leftInput = StreamController<Uint8List>();
    final rightInput = StreamController<Uint8List>();
    final leftOutput = StreamController<List<int>>();
    final rightOutput = StreamController<List<int>>();
    final receivedByLeft = <int>[];
    final receivedByRight = <int>[];
    leftOutput.stream.listen(receivedByLeft.addAll);
    rightOutput.stream.listen(receivedByRight.addAll);

    final pumping = pumpBidirectionalStreams(
      leftInput: leftInput.stream,
      leftOutput: leftOutput.sink,
      rightInput: rightInput.stream,
      rightOutput: rightOutput.sink,
    );
    leftInput.add(Uint8List.fromList([1, 2]));
    rightInput.add(Uint8List.fromList([7]));
    leftInput.add(Uint8List.fromList([3]));
    rightInput.add(Uint8List.fromList([8, 9]));
    await leftInput.close();
    await rightInput.close();

    await pumping;
    expect(receivedByLeft, [7, 8, 9]);
    expect(receivedByRight, [1, 2, 3]);
  });

  test('tunnel exposes only an immutable bearer header', () async {
    final tunnel = await CodexTunnel.open(
      _ConnectedTransport(),
      4500,
      capabilityToken: fakeToken,
    );
    addTearDown(tunnel.close);

    expect(tunnel.clientHeaders, <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
    });
    expect(
      () => tunnel.clientHeaders['another'] = 'value',
      throwsUnsupportedError,
    );
  });

  test('WebSocket authentication rejects missing and wrong tokens', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final attempts = <String?>[];
    final subscription = server.listen((request) async {
      final authorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      attempts.add(authorization);
      if (authorization != 'Bearer $fakeToken') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    final authenticated = await verifyWebSocketCapabilityAuthentication(
      Uri.parse('ws://127.0.0.1:${server.port}'),
      const <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
      },
    );

    expect(authenticated, isTrue);
    expect(attempts, <String?>[
      null,
      'Bearer invalid-capability-token',
      'Bearer $fakeToken',
    ]);
  });

  test('network failure is not accepted as authentication rejection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri.parse('ws://127.0.0.1:${server.port}');
    await server.close(force: true);

    expect(
      await verifyWebSocketCapabilityAuthentication(uri, const <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
      }, timeout: const Duration(milliseconds: 100)),
      isFalse,
    );
  });

  test('probe timeout is not accepted as authentication rejection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((_) {});
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    expect(
      await verifyWebSocketCapabilityAuthentication(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        const <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
        },
        timeout: const Duration(milliseconds: 20),
      ),
      isFalse,
    );
  });

  test('a late authenticated WebSocket is closed after timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final lateSocketClosed = Completer<void>();
    final subscription = server.listen((request) async {
      final authorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      if (authorization != 'Bearer $fakeToken') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (_) {},
        onDone: () {
          if (!lateSocketClosed.isCompleted) lateSocketClosed.complete();
        },
      );
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    expect(
      await verifyWebSocketCapabilityAuthentication(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        const <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
        },
        timeout: const Duration(milliseconds: 20),
      ),
      isFalse,
    );
    await lateSocketClosed.future.timeout(const Duration(seconds: 1));
  });
}

class _ConnectedTransport implements SshTransport {
  @override
  bool get isConnected => true;

  @override
  ServerProfile get profile => const ServerProfile(
    id: 'id',
    name: 'Server',
    host: 'host',
    username: 'user',
    authentication: SshAuthentication.password,
  );

  @override
  Future<RemoteCommandResult> executeCommand(
    String executable,
    Iterable<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
  }) => throw UnsupportedError('Not used by this test');

  @override
  Future<SSHForwardChannel> forwardLoopback(int remotePort) =>
      throw UnsupportedError('Not used by this test');
}
