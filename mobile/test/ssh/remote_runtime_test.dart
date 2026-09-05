import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

void main() {
  test('an existing unready runtime is never killed or replaced', () async {
    final transport = RecordingTransport((command) {
      if (command.contains('command -v codex')) return success();
      if (command.contains("codex '--version'")) {
        return success(stdout: 'codex-cli 0.153.4\n');
      }
      if (command.contains("tmux 'has-session'")) return success();
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
