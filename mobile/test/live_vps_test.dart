import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_secret.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

const fixtureToken = String.fromEnvironment('POCKET_FIXTURE_TOKEN');
const fixturePort = String.fromEnvironment(
  'POCKET_FIXTURE_PORT',
  defaultValue: '18089',
);

Future<Map<String, dynamic>> loadFixture() async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(
      Uri.parse('http://127.0.0.1:$fixturePort/config'),
    );
    request.headers.set('Authorization', 'Bearer $fixtureToken');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('Private fixture unavailable');
    }
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    http.close(force: true);
  }
}

SshConnection makeConnection(
  Map<String, dynamic> fixture, {
  bool wrongPin = false,
}) => SshConnection(
  profile: ServerProfile(
    id: fixture['id'] as String,
    name: 'Validation server',
    host: fixture['host'] as String,
    port: fixture['port'] as int,
    username: fixture['username'] as String,
    authentication: SshAuthentication.password,
    hostKeyType: fixture['hostKeyType'] as String,
    hostKeyFingerprint: wrongPin
        ? 'SHA256:wrong'
        : fixture['hostKeyFingerprint'] as String,
    remoteCodexPort: fixture['remoteCodexPort'] as int,
  ),
  secret: ServerSecret(password: fixture['password'] as String),
);

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Expected validation state was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test(
    'live VPS: host pin, PTY resize, persistent shell, Codex turn and reconnect',
    () async {
      final fixture = await loadFixture();
      final wrong = makeConnection(fixture, wrongPin: true);
      await expectLater(
        wrong.connect(onFirstUseHostKey: (_) async => false),
        throwsA(anything),
      );
      await wrong.disconnect();

      var ssh = makeConnection(fixture);
      CodexTunnel? tunnel;
      CodexClient? rpc;
      final termId = 'validation-${DateTime.now().millisecondsSinceEpoch}';
      var terminalDeleted = false;
      try {
        await ssh.connect(onFirstUseHostKey: (_) async => false);
        final plain = await ssh.openShell();
        var plainOutput = '';
        final plainSubscription = utf8.decoder
            .bind(plain.output)
            .listen((chunk) => plainOutput += chunk);
        plain.resize(101, 33);
        plain.write("printf '__PLAIN_%s__\\n' PTY; stty size\r");
        await eventually(
          () =>
              plainOutput.contains('__PLAIN_PTY__') &&
              plainOutput.contains('33 101'),
        );
        await plain.close();
        await plainSubscription.cancel();
        // ignore: avoid_print
        print('Verified direct SSH PTY and resize');
        final pty = await ssh.createPersistentShell(id: termId);
        var output = '';
        final outputSubscription = utf8.decoder
            .bind(pty.output)
            .listen((chunk) => output += chunk);
        pty.resize(101, 33);
        pty.write(
          "export POCKET_SENTINEL=persistent; printf '__POCKET_%s__\\n' PTY; stty size\r",
        );
        await eventually(() => output.contains('__POCKET_PTY__'));
        await pty.close();
        await outputSubscription.cancel();
        await ssh.disconnect();
        // ignore: avoid_print
        print('Detached persistent SSH shell');

        ssh = makeConnection(fixture);
        await ssh.connect(onFirstUseHostKey: (_) async => false);
        final attached = await ssh.attachPersistentShell(termId);
        var recovered = '';
        final attachedSubscription = utf8.decoder
            .bind(attached.output)
            .listen((chunk) => recovered += chunk);
        attached.write("printf '__RESTORED_%s__\\n' \"\$POCKET_SENTINEL\"\r");
        await eventually(() => recovered.contains('__RESTORED_persistent__'));
        await attached.close();
        await attachedSubscription.cancel();
        await ssh.deletePersistentShell(termId);
        terminalDeleted = true;
        // ignore: avoid_print
        print('Verified persistent shell reattach');

        final runtime = RemoteRuntimeManager(ssh);
        final runtimeStatus = await runtime.inspect();
        // ignore: avoid_print
        print(
          'Runtime readiness: ${runtimeStatus.running}; ${runtimeStatus.diagnostic ?? "ready"}',
        );
        expect(runtimeStatus.running, isTrue);
        tunnel = await runtime.openTunnel();
        rpc = await CodexClient.connect(
          tunnel.uri,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        );
        // ignore: avoid_print
        print('Initialized real Codex app-server');
        final account = await rpc.readAccount();
        // ignore: avoid_print
        print(
          'Account status: authenticated=${account.isAuthenticated}; '
          'kind=${account.kind.name}',
        );
        final models = await rpc.listModels();
        expect(models.data, isNotEmpty);
        final selected =
            models.data
                .where((item) => item.model == 'gpt-5.6-sol')
                .firstOrNull ??
            models.data.first;
        // ignore: avoid_print
        print('Selected model: ${selected.model}');
        final thread = await rpc.startThread(
          cwd: fixture['cwd'] as String,
          model: selected.model,
        );
        expect(thread.id, isNotEmpty);
        final complete = rpc.turnSnapshots.firstWhere(
          (event) => event.threadId == thread.id && event.completed,
        );
        await rpc.sendMessage(
          thread.id,
          'Reply exactly POCKET_CODEX_OK. Do not use tools.',
          effort: 'low',
        );
        final completed = await complete.timeout(const Duration(minutes: 2));
        if (completed.turn.status != 'completed') {
          final diagnostic = _safeTurnError(completed.turn.error);
          // ignore: avoid_print
          print(
            'Turn failure: type=${diagnostic.type}; '
            'httpCode=${diagnostic.httpCode ?? "none"}; '
            'error=${diagnostic.summary}',
          );
        }
        expect(
          completed.turn.status,
          'completed',
          reason: 'Live Codex turn must complete successfully',
        );
        final history = await rpc.readThread(thread.id);
        expect(jsonEncode(history.raw), contains('POCKET_CODEX_OK'));
        expect(
          (await rpc.listThreads(cwd: fixture['cwd'] as String)).data
              .any((item) => item.id == thread.id),
          isTrue,
        );
        await rpc.listSkills(cwds: [fixture['cwd'] as String]);
        await rpc.dispose();
        rpc = null;
        await tunnel.close();
        tunnel = null;
        await ssh.disconnect();

        ssh = makeConnection(fixture);
        await ssh.connect(onFirstUseHostKey: (_) async => false);
        tunnel = await RemoteRuntimeManager(ssh).openTunnel();
        rpc = await CodexClient.connect(
          tunnel.uri,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        );
        final restored = await rpc.openThread(thread.id);
        expect(jsonEncode(restored.raw), contains('POCKET_CODEX_OK'));
        await rpc.archiveThread(thread.id);
      } finally {
        await rpc?.dispose();
        await tunnel?.close();
        if (ssh.isConnected && !terminalDeleted) {
          final remaining = await ssh.listPersistentShells();
          if (remaining.any((item) => item.id == termId)) {
            await ssh.deletePersistentShell(termId);
          }
        }
        await ssh.disconnect();
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

({String type, int? httpCode, String summary}) _safeTurnError(Object? error) {
  final httpCode = _findIntField(error, const {
    'httpStatusCode',
    'http_status_code',
    'statusCode',
    'status_code',
  });
  final message = error is String
      ? error
      : _findStringField(error, const {'message', 'detail', 'reason'}) ??
            'unavailable';
  final type =
      _findStringField(error, const {'type', 'code', 'kind'}) ??
      _classifyTurnError(message) ??
      error.runtimeType.toString();
  return (
    type: _redact(message: type, maxLength: 80),
    httpCode: httpCode,
    summary: _redact(message: message, maxLength: 240),
  );
}

String? _classifyTurnError(String message) {
  final normalized = message.toLowerCase();
  if (normalized.contains('refresh token') && normalized.contains('revoked')) {
    return 'authentication_refresh_revoked';
  }
  if (normalized.contains('access token') ||
      normalized.contains('authentication') ||
      normalized.contains('unauthorized')) {
    return 'authentication';
  }
  if (normalized.contains('model') &&
      (normalized.contains('not found') ||
          normalized.contains('not supported') ||
          normalized.contains('access'))) {
    return 'model_access';
  }
  if (normalized.contains('network') || normalized.contains('connection')) {
    return 'network';
  }
  return null;
}

String? _findStringField(Object? value, Set<String> keys, [int depth = 0]) {
  if (depth > 4) return null;
  if (value is Map) {
    for (final entry in value.entries) {
      if (keys.contains(entry.key.toString()) && entry.value is String) {
        return entry.value as String;
      }
    }
    for (final nested in value.values) {
      final found = _findStringField(nested, keys, depth + 1);
      if (found != null) return found;
    }
  } else if (value is Iterable) {
    for (final nested in value) {
      final found = _findStringField(nested, keys, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

int? _findIntField(Object? value, Set<String> keys, [int depth = 0]) {
  if (depth > 4) return null;
  if (value is Map) {
    for (final entry in value.entries) {
      if (keys.contains(entry.key.toString()) && entry.value is num) {
        return (entry.value as num).toInt();
      }
    }
    for (final nested in value.values) {
      final found = _findIntField(nested, keys, depth + 1);
      if (found != null) return found;
    }
  } else if (value is Iterable) {
    for (final nested in value) {
      final found = _findIntField(nested, keys, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

String _redact({required String message, required int maxLength}) {
  var value = message
      .replaceAll(
        RegExp(r'bearer\s+\S+', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        ),
        '[JWT]',
      )
      .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]+\b'), '[TOKEN]')
      .replaceAll(
        RegExp(
          r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
          caseSensitive: false,
        ),
        '[EMAIL]',
      )
      .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[IP]')
      .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[URL]')
      .replaceAll(RegExp(r'\b[A-Za-z0-9_=-]{32,}\b'), '[SECRET]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.length > maxLength) value = '${value.substring(0, maxLength)}…';
  return value.isEmpty ? 'unavailable' : value;
}
