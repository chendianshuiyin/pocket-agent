import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_secret.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

void main() {
  test(
    'disconnect during authentication cannot transition back to connected',
    () async {
      final driver = FakeDriver();
      final connection = SshConnection(
        profile: profile(),
        secret: ServerSecret(password: 'password'),
        driverFactory: FakeDriverFactory(driver),
      );

      final connecting = connection.connect(
        onFirstUseHostKey: (_) async => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(connection.state, SshConnectionState.connecting);

      await connection.disconnect();
      driver.authentication.complete();

      await expectLater(
        connecting,
        throwsA(isA<SshConnectionCancelledException>()),
      );
      expect(connection.state, SshConnectionState.disconnected);
      expect(connection.isConnected, isFalse);
    },
  );

  test(
    'terminal list and delete use only the terminal tmux namespace',
    () async {
      final driver = FakeDriver()
        ..authentication.complete()
        ..runHandler = (command) {
          if (command.contains("'list-sessions'")) {
            return result(
              'pocket-agent-term-alpha\t0\n'
              'pocket-agent-runtime-codex-4500\t0\n',
            );
          }
          return result('');
        };
      final connection = SshConnection(
        profile: profile(),
        secret: ServerSecret(password: 'password'),
        driverFactory: FakeDriverFactory(driver),
      );
      await connection.connect(onFirstUseHostKey: (_) async => true);

      final shells = await connection.listPersistentShells();
      await connection.deletePersistentShell('alpha');

      expect(shells.map((item) => item.id), ['alpha']);
      expect(driver.commands.last, contains("'=pocket-agent-term-alpha'"));
      expect(driver.commands.last, isNot(contains('runtime-codex')));
      await connection.disconnect();
    },
  );
}

ServerProfile profile() => const ServerProfile(
  id: 'id',
  name: 'Server',
  host: 'host',
  username: 'user',
  authentication: SshAuthentication.password,
  hostKeyType: 'ssh-ed25519',
  hostKeyFingerprint: 'SHA256:pinned',
);

SSHRunResult result(String stdout) => SSHRunResult(
  output: Uint8List.fromList(stdout.codeUnits),
  stdout: Uint8List.fromList(stdout.codeUnits),
  stderr: Uint8List(0),
  exitCode: 0,
  exitSignal: null,
);

class FakeDriverFactory implements SshDriverFactory {
  FakeDriverFactory(this.driver);
  final FakeDriver driver;

  @override
  Future<SshConnectionDriver> create({
    required ServerProfile profile,
    required ServerSecret secret,
    required RawHostKeyVerifier verifyHostKey,
    required Duration connectTimeout,
    required Duration authTimeout,
  }) async => driver;
}

class FakeDriver implements SshConnectionDriver {
  final Completer<void> authentication = Completer<void>();
  final Completer<void> completion = Completer<void>();
  final List<String> commands = [];
  SSHRunResult Function(String command)? runHandler;
  bool closed = false;

  @override
  bool get isClosed => closed;
  @override
  Future<void> get authenticated => authentication.future;
  @override
  Future<void> get done => completion.future;

  @override
  Future<void> close() async {
    closed = true;
    if (!completion.isCompleted) completion.complete();
  }

  @override
  Future<SSHSession> execute(String command, SSHPtyConfig pty) =>
      throw UnsupportedError('Not used by this test');

  @override
  Future<SSHForwardChannel> forwardLoopback(int remotePort) =>
      throw UnsupportedError('Not used by this test');

  @override
  Future<SSHRunResult> runWithResult(String command) async {
    commands.add(command);
    return runHandler?.call(command) ?? result('');
  }

  @override
  Future<SSHSession> shell(SSHPtyConfig pty) =>
      throw UnsupportedError('Not used by this test');
}
