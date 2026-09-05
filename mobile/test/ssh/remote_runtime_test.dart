import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

const fakeToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  test('an existing unready runtime is never killed or replaced', () async {
    final transport = RecordingTransport((command) {
      if (command.contains('command -v codex')) return success();
      if (command.contains("codex '--version'")) {
        return success(stdout: 'codex-cli 0.153.4\n');
      }
      if (command.contains("tmux 'has-session'")) return success();
      if (command.contains('cat <&3')) return success(stdout: fakeToken);
      return success();
    });
    final manager = RemoteRuntimeManager(
      transport,
      readinessProbe: () async => false,
      portListeningProbe: () async => false,
    );

    await expectLater(manager.ensureRunning(), throwsA(isA<StateError>()));

    expect(
      transport.commands.where((item) => item.contains('kill-session')),
      isEmpty,
    );
    expect(
      transport.commands.where((item) => item.contains('new-session')),
      isEmpty,
    );
    expect(
      transport.commands,
      contains(contains("'=pocket-agent-runtime-codex-4500'")),
    );
  });

  test(
    'a legacy unauthenticated runtime is refused without disruption',
    () async {
      var probed = false;
      final transport = RecordingTransport((command) {
        if (command.contains('command -v codex')) return success();
        if (command.contains("codex '--version'")) {
          return success(stdout: 'version');
        }
        if (command.contains("tmux 'has-session'")) return success();
        if (command.contains('cat <&3')) return failure();
        return success();
      });
      final manager = RemoteRuntimeManager(
        transport,
        readinessProbe: () async {
          probed = true;
          return true;
        },
        portListeningProbe: () async => false,
      );

      await expectLater(manager.ensureRunning(), throwsA(isA<StateError>()));

      expect(probed, isFalse);
      expect(
        transport.commands.where((item) => item.contains('kill-session')),
        isEmpty,
      );
      expect(
        transport.commands.where((item) => item.contains('new-session')),
        isEmpty,
      );
    },
  );

  test('an occupied port without an owned runtime refuses startup', () async {
    final transport = RecordingTransport((command) {
      if (command.contains('command -v codex')) return success();
      if (command.contains("codex '--version'")) {
        return success(stdout: 'version');
      }
      if (command.contains("tmux 'has-session'")) return failure();
      return success();
    });
    final manager = RemoteRuntimeManager(
      transport,
      readinessProbe: () async => false,
      portListeningProbe: () async => true,
    );

    await expectLater(manager.ensureRunning(), throwsA(isA<StateError>()));

    expect(
      transport.commands.where((item) => item.contains('new-session')),
      isEmpty,
    );
    expect(
      transport.commands,
      contains(contains("'=pocket-agent-runtime-codex-4500'")),
    );
  });

  test(
    'a new runtime uses a private token file without token argv exposure',
    () async {
      final transport = RecordingTransport((command) {
        if (command.contains('command -v codex')) return success();
        if (command.contains("codex '--version'")) {
          return success(stdout: 'version');
        }
        if (command.contains("tmux 'has-session'")) return failure();
        if (command.contains('/dev/urandom')) return success(stdout: fakeToken);
        return success();
      });
      final manager = RemoteRuntimeManager(
        transport,
        readinessProbe: () async => true,
        portListeningProbe: () async => false,
      );

      final status = await manager.ensureRunning();

      expect(status.running, isTrue);
      final start = transport.commands.singleWhere(
        (item) => item.contains("tmux 'new-session'"),
      );
      expect(start, contains('--ws-auth'));
      expect(start, contains('capability-token'));
      expect(start, contains('--ws-token-file'));
      expect(start, contains(r'$HOME/.pocket-agent/app-server-4500.token'));
      expect(start, isNot(contains(fakeToken)));
      final initialization = transport.commands.singleWhere(
        (item) => item.contains('/dev/urandom'),
      );
      expect(initialization, contains("stat -c '%a'"));
      expect(initialization, contains(r'[ ! -L "$token_file" ]'));
      expect(initialization, contains("= '600'"));
      expect(
        initialization.indexOf(r'${#candidate}'),
        lessThan(initialization.indexOf(r'ln "$temp" "$token_file"')),
      );
    },
  );

  test(
    'invalid generated token output is never followed by runtime start',
    () async {
      final transport = RecordingTransport((command) {
        if (command.contains('command -v codex')) return success();
        if (command.contains("codex '--version'")) {
          return success(stdout: 'version');
        }
        if (command.contains("tmux 'has-session'")) return failure();
        if (command.contains('/dev/urandom')) return success(stdout: 'short');
        return success();
      });
      final manager = RemoteRuntimeManager(
        transport,
        readinessProbe: () async => true,
        portListeningProbe: () async => false,
      );

      await expectLater(manager.ensureRunning(), throwsA(isA<StateError>()));

      expect(
        transport.commands.where((item) => item.contains('new-session')),
        isEmpty,
      );
    },
  );

  test('openExistingTunnel never creates a missing runtime or token', () async {
    final transport = RecordingTransport((command) {
      if (command.contains("codex '--version'")) {
        return success(stdout: 'version');
      }
      if (command.contains("tmux 'has-session'")) return failure();
      return success();
    });
    final manager = RemoteRuntimeManager(transport);

    await expectLater(manager.openExistingTunnel(), throwsA(isA<StateError>()));

    expect(
      transport.commands.where((item) => item.contains('new-session')),
      isEmpty,
    );
    expect(
      transport.commands.where((item) => item.contains('/dev/urandom')),
      isEmpty,
    );
    expect(
      transport.commands.where((item) => item.contains('cat <&3')),
      isEmpty,
    );
  });

  test(
    'openExistingTunnel returns headers for an authenticated runtime',
    () async {
      final transport = RecordingTransport((command) {
        if (command.contains("codex '--version'")) {
          return success(stdout: 'version');
        }
        if (command.contains("tmux 'has-session'")) return success();
        if (command.contains('cat <&3')) return success(stdout: fakeToken);
        return success();
      });
      final manager = RemoteRuntimeManager(
        transport,
        readinessProbe: () async => true,
      );

      final tunnel = await manager.openExistingTunnel();
      addTearDown(tunnel.close);

      expect(tunnel.clientHeaders, <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $fakeToken',
      });
      expect(
        transport.commands.where((item) => item.contains('new-session')),
        isEmpty,
      );
      expect(
        transport.commands.where((item) => item.contains('/dev/urandom')),
        isEmpty,
      );
    },
  );
}

RemoteCommandResult success({String stdout = ''}) =>
    RemoteCommandResult(stdout: stdout, stderr: '', exitCode: 0);

RemoteCommandResult failure() =>
    const RemoteCommandResult(stdout: '', stderr: '', exitCode: 1);

class RecordingTransport implements SshTransport {
  RecordingTransport(this.handler);

  final RemoteCommandResult Function(String command) handler;
  final List<String> commands = [];

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
  }) async {
    final command = '$executable ${arguments.join(' ')}';
    commands.add(command);
    return handler(command);
  }

  @override
  Future<SSHForwardChannel> forwardLoopback(int remotePort) =>
      throw UnsupportedError('Not used by this test');
}
