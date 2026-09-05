import 'dart:async';

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
  // Transport-only capability: keep it out of profiles, UI, and diagnostics.
  String? _runtimeToken;

  String get _sessionName => 'pocket-agent-runtime-codex-$remotePort';
  String get _tokenRelativePath => '.pocket-agent/app-server-$remotePort.token';

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

    final token = await _readRuntimeToken();
    if (token == null) {
      return RemoteRuntimeStatus(
        running: false,
        codexVersion: version,
        remotePort: remotePort,
        diagnostic: 'app-server runtime authentication is unavailable',
      );
    }
    final healthy = await _probeThroughNewTunnel(token);
    if (healthy) _runtimeToken = token;
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
          'command -v tmux >/dev/null 2>&1 && '
          'command -v mktemp >/dev/null 2>&1 && '
          'command -v od >/dev/null 2>&1 && '
          'command -v stat >/dev/null 2>&1 && '
          'command -v tr >/dev/null 2>&1',
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
      final token = await _readRuntimeToken();
      if (token == null) {
        throw StateError(
          'Existing remote Codex runtime is not authentication-managed',
        );
      }
      if (await _probeThroughNewTunnel(token)) {
        _runtimeToken = token;
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
    final token = await _initializeRuntimeToken();
    final codexCommand = buildShellCommand('codex', [
      'app-server',
      '--listen',
      'ws://127.0.0.1:$remotePort',
      '--ws-auth',
      'capability-token',
      '--ws-token-file',
    ]);
    final appServerCommand = buildShellCommand('sh', [
      '-lc',
      'PATH="\$HOME/.local/bin:\$PATH"; export PATH; '
          'token_file="\$HOME/$_tokenRelativePath"; '
          'exec $codexCommand "\$token_file"',
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
      if (await _probeThroughNewTunnel(token)) {
        _runtimeToken = token;
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
    return _openAuthenticatedTunnel();
  }

  Future<CodexTunnel> openExistingTunnel() async {
    final status = await inspect();
    if (!status.running) {
      throw StateError('Existing remote Codex runtime is unavailable');
    }
    return _openAuthenticatedTunnel();
  }

  Future<CodexTunnel> _openAuthenticatedTunnel() {
    final token = _runtimeToken;
    if (token == null) {
      throw StateError('Remote Codex runtime authentication is unavailable');
    }
    return CodexTunnel.open(connection, remotePort, capabilityToken: token);
  }

  Future<String?> _codexVersion() async {
    final result = await _runWithUserPath('codex', const ['--version']);
    if (!result.succeeded) return null;
    final value = result.stdout.trim();
    return value.isEmpty ? null : value;
  }

  Future<bool> _probeThroughNewTunnel(String token) async {
    final override = _readinessProbe;
    if (override != null) return override();
    _lastProbeDiagnostic = null;
    CodexTunnel? tunnel;
    var stage = 'open-tunnel';
    try {
      tunnel = await CodexTunnel.open(
        connection,
        remotePort,
        capabilityToken: token,
      );
      stage = 'verify-authentication';
      final healthy = await verifyWebSocketCapabilityAuthentication(
        tunnel.uri,
        tunnel.clientHeaders,
      );
      if (!healthy) {
        _lastProbeDiagnostic = 'app-server WebSocket authentication failed';
      }
      return healthy;
    } catch (error) {
      final tunnelFailure = tunnel?.lastFailureType;
      _lastProbeDiagnostic =
          'app-server readiness probe failed at $stage (${error.runtimeType}'
          '${tunnelFailure == null ? '' : ', tunnel $tunnelFailure'})';
      return false;
    } finally {
      await tunnel?.close();
    }
  }

  Future<String?> _readRuntimeToken() async {
    final result = await connection.executeCommand('sh', [
      '-lc',
      _tokenValidationScript(createIfMissing: false),
    ]);
    if (!result.succeeded) return null;
    return _parseRuntimeToken(result.stdout);
  }

  Future<String> _initializeRuntimeToken() async {
    final result = await connection.executeCommand('sh', [
      '-lc',
      _tokenValidationScript(createIfMissing: true),
    ]);
    final token = result.succeeded ? _parseRuntimeToken(result.stdout) : null;
    if (token == null) {
      throw StateError('Failed to initialize remote runtime authentication');
    }
    return token;
  }

  String _tokenValidationScript({required bool createIfMissing}) {
    final initialize = createIfMissing
        ? '''
if [ ! -e "\$token_file" ]; then
  temp="\$(umask 077; mktemp "\$token_file.tmp.XXXXXX")"
  trap 'rm -f -- "\$temp"' EXIT HUP INT TERM
  (umask 077; od -An -v -N32 -tx1 /dev/urandom | tr -d '[:space:]' > "\$temp")
  [ ! -L "\$temp" ] && [ -f "\$temp" ] || exit 74
  [ "\$(stat -c '%u' -- "\$temp")" = "\$uid" ] || exit 74
  [ "\$(stat -c '%a' -- "\$temp")" = '600' ] || exit 74
  candidate="\$(cat -- "\$temp")"
  case "\$candidate" in *[!a-f0-9]*|'') exit 74;; esac
  [ "\${#candidate}" -eq 64 ] || exit 74
  unset candidate
  if ! ln "\$temp" "\$token_file" 2>/dev/null; then
    [ -e "\$token_file" ] || exit 74
  fi
  rm -f -- "\$temp"
  trap - EXIT HUP INT TERM
fi
'''
        : '';
    return '''
set -eu
token_dir="\$HOME/.pocket-agent"
token_file="\$HOME/$_tokenRelativePath"
uid="\$(id -u)"
if [ -L "\$token_dir" ] ||
   { [ -e "\$token_dir" ] && [ ! -d "\$token_dir" ]; }; then
  exit 73
fi
if [ ! -e "\$token_dir" ]; then
  ${createIfMissing ? 'if ! mkdir -m 700 -- "\$token_dir" 2>/dev/null; then [ -d "\$token_dir" ] || exit 73; fi' : 'exit 73'}
fi
[ ! -L "\$token_dir" ] && [ -d "\$token_dir" ] || exit 73
[ "\$(stat -c '%u' -- "\$token_dir")" = "\$uid" ] || exit 73
[ "\$(stat -c '%a' -- "\$token_dir")" = '700' ] || exit 73
$initialize
[ ! -L "\$token_file" ] && [ -f "\$token_file" ] || exit 74
exec 3< "\$token_file"
[ -f /proc/self/fd/3 ] || exit 74
[ "\$(stat -Lc '%u' -- /proc/self/fd/3)" = "\$uid" ] || exit 74
[ "\$(stat -Lc '%a' -- /proc/self/fd/3)" = '600' ] || exit 74
[ "\$(stat -Lc '%h' -- /proc/self/fd/3)" = '1' ] || exit 74
token="\$(cat <&3)"
exec 3<&-
case "\$token" in *[!a-f0-9]*|'') exit 74;; esac
[ "\${#token}" -eq 64 ] || exit 74
printf '%s' "\$token"
''';
  }

  String? _parseRuntimeToken(String output) {
    final token = output.trim();
    return RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ? token : null;
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
