import 'dart:async';
import 'dart:io';

import 'codex_tunnel.dart';
import 'shell_command.dart';
import 'ssh_connection.dart';

class RemoteRuntimeStatus {
  const RemoteRuntimeStatus({
    required this.running,
    required this.codexVersion,
    required this.remotePort,
    this.diagnostic,
  });

  final bool running;
  final String? codexVersion;
  final int remotePort;
  final String? diagnostic;
}

class RemoteRuntimeManager {
  RemoteRuntimeManager(
    this.connection, {
    int? remotePort,
    this.startupTimeout = const Duration(seconds: 20),
    Future<bool> Function()? readinessProbe,
    Future<bool> Function()? portListeningProbe,
  }) : remotePort = remotePort ?? connection.profile.remoteCodexPort {
    if (this.remotePort < 1 || this.remotePort > 65535) {
      throw ArgumentError.value(
        this.remotePort,
        'remotePort',
        'must be a valid port',
      );
    }
    _readinessProbe = readinessProbe;
    _portListeningProbe = portListeningProbe;
  }

  final SshTransport connection;
  final int remotePort;
  final Duration startupTimeout;
  late final Future<bool> Function()? _readinessProbe;
  late final Future<bool> Function()? _portListeningProbe;
  String? _lastProbeDiagnostic;

  String get _sessionName => 'pocket-agent-runtime-codex-$remotePort';

  Future<RemoteRuntimeStatus> inspect() async {
    _requireConnected();
    final version = await _codexVersion();
    final tmux = await _runWithUserPath('tmux', [
      'has-session',
      '-t',
      '=$_sessionName',
    ]);
    if (!tmux.succeeded) {
      return RemoteRuntimeStatus(
        running: false,
        codexVersion: version,
        remotePort: remotePort,
        diagnostic: 'Pocket Agent app-server tmux session is not running',
      );
    }

    final healthy = await _probeThroughNewTunnel();
    return RemoteRuntimeStatus(
      running: healthy,
      codexVersion: version,
      remotePort: remotePort,
      diagnostic: healthy
          ? null
          : _lastProbeDiagnostic ?? 'app-server readiness probe failed',
    );
  }

  Future<RemoteRuntimeStatus> ensureRunning() async {
    _requireConnected();
    final prerequisites = await connection.executeCommand('sh', const [
      '-lc',
      'PATH="\$HOME/.local/bin:\$PATH"; export PATH; '
          'command -v codex >/dev/null 2>&1 && '
          'command -v tmux >/dev/null 2>&1',
    ]);
    if (!prerequisites.succeeded) {
      throw StateError(
        'Remote codex and tmux must already be installed and available in PATH',
      );
    }

    final version = await _codexVersion();
    final existing = await _runWithUserPath('tmux', [
      'has-session',
      '-t',
      '=$_sessionName',
    ]);
    if (existing.succeeded) {
      if (await _probeThroughNewTunnel()) {
        return RemoteRuntimeStatus(
          running: true,
          codexVersion: version,
          remotePort: remotePort,
        );
      }
      throw StateError(
        'Pocket Agent runtime is still present but not ready; retry later',
      );
    }
    if (await _isRemotePortListening()) {
      throw StateError(
        'Remote loopback port is already used by an unmanaged service',
      );
    }
    final codexCommand = buildShellCommand('codex', [
      'app-server',
      '--listen',
      'ws://127.0.0.1:$remotePort',
    ]);
    final appServerCommand = buildShellCommand('sh', [
      '-lc',
      'PATH="\$HOME/.local/bin:\$PATH"; export PATH; exec $codexCommand',
    ]);
    final start = await _runWithUserPath('tmux', [
      'new-session',
      '-d',
      '-s',
      _sessionName,
      appServerCommand,
    ]);
    if (!start.succeeded) {
      throw StateError('Failed to start the remote Codex app-server');
    }

    final deadline = DateTime.now().add(startupTimeout);
    do {
      if (await _probeThroughNewTunnel()) {
        return RemoteRuntimeStatus(
          running: true,
          codexVersion: version,
          remotePort: remotePort,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } while (DateTime.now().isBefore(deadline));

    throw StateError('Remote Codex app-server did not become ready in time');
  }

  Future<CodexTunnel> openTunnel() async {
    await ensureRunning();
    return CodexTunnel.open(connection, remotePort);
  }

  Future<String?> _codexVersion() async {
    final result = await _runWithUserPath('codex', const ['--version']);
    if (!result.succeeded) return null;
    final value = result.stdout.trim();
    return value.isEmpty ? null : value;
  }

  Future<bool> _probeThroughNewTunnel() async {
    final override = _readinessProbe;
    if (override != null) return override();
    _lastProbeDiagnostic = null;
    CodexTunnel? tunnel;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    var stage = 'open-tunnel';
    try {
      tunnel = await CodexTunnel.open(connection, remotePort);
      stage = 'send-request';
      final request = await client
          .getUrl(tunnel.uri.replace(scheme: 'http', path: '/readyz'))
          .timeout(const Duration(seconds: 2));
      stage = 'read-response';
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>().timeout(const Duration(seconds: 2));
      final healthy = response.statusCode >= 200 && response.statusCode < 300;
      if (!healthy) {
        _lastProbeDiagnostic =
            'app-server readiness probe returned HTTP ${response.statusCode}';
      }
      return healthy;
    } catch (error) {
      final tunnelFailure = tunnel?.lastFailureType;
      _lastProbeDiagnostic =
          'app-server readiness probe failed at $stage (${error.runtimeType}'
          '${tunnelFailure == null ? '' : ', tunnel $tunnelFailure'})';
      return false;
    } finally {
      client.close(force: true);
      await tunnel?.close();
    }
  }

  Future<bool> _isRemotePortListening() async {
    final override = _portListeningProbe;
    if (override != null) return override();
    final portHex = remotePort.toRadixString(16).padLeft(4, '0').toUpperCase();
    final result = await connection.executeCommand('sh', [
      '-lc',
      "awk '\$2 ~ /:$portHex\$/ && \$4 == \"0A\" { found=1 } "
          "END { exit found ? 0 : 1 }' /proc/net/tcp /proc/net/tcp6 "
          '2>/dev/null',
    ]);
    return result.succeeded;
  }

  Future<RemoteCommandResult> _runWithUserPath(
    String executable,
    Iterable<String> arguments,
  ) {
    final command = buildShellCommand(executable, arguments);
    return connection.executeCommand('sh', [
      '-lc',
      'PATH="\$HOME/.local/bin:\$PATH"; export PATH; exec $command',
    ]);
  }

  void _requireConnected() {
    if (!connection.isConnected) {
      throw StateError('SSH connection is not connected');
    }
  }
}
