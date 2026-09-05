import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../core/server_profile.dart';
import '../core/server_repository.dart';
import '../core/server_secret.dart';
import 'pty_session.dart';
import 'queued_ssh_socket.dart';
import 'shell_command.dart';

enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  failed,
}

class HostKeyCandidate {
  const HostKeyCandidate({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
}

typedef HostKeyConfirmation = Future<bool> Function(HostKeyCandidate candidate);
typedef RawHostKeyVerifier = Future<bool> Function(
  String keyType,
  String fingerprint,
);

class RemoteCommandResult {
  const RemoteCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
  final String stdout;
  final String stderr;
  final int? exitCode;
  bool get succeeded => exitCode == 0;
}

abstract interface class SshTransport {
  ServerProfile get profile;
  bool get isConnected;
  Future<RemoteCommandResult> executeCommand(
    String executable,
    Iterable<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
  });
  Future<SSHForwardChannel> forwardLoopback(int remotePort);
}

abstract interface class SshConnectionDriver {
  bool get isClosed;
  Future<void> get authenticated;
  Future<void> get done;
  Future<SSHSession> shell(SSHPtyConfig pty);
  Future<SSHSession> execute(String command, SSHPtyConfig pty);
  Future<SSHRunResult> runWithResult(String command);
  Future<SSHForwardChannel> forwardLoopback(int remotePort);
  Future<void> close();
}

abstract interface class SshDriverFactory {
  Future<SshConnectionDriver> create({
    required ServerProfile profile,
    required ServerSecret secret,
    required RawHostKeyVerifier verifyHostKey,
    required Duration connectTimeout,
    required Duration authTimeout,
  });
}

class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException({
    required this.host,
    required this.port,
    required this.expectedType,
    required this.expectedFingerprint,
    required this.actualType,
    required this.actualFingerprint,
  });
  final String host;
  final int port;
  final String expectedType;
  final String expectedFingerprint;
  final String actualType;
  final String actualFingerprint;
  @override
  String toString() => 'SSH host key does not match the pinned host key';
}

class HostKeyRejectedException implements Exception {
  const HostKeyRejectedException();
  @override
  String toString() => 'SSH host key was rejected';
}

class SshConnectionCancelledException implements Exception {
  const SshConnectionCancelledException();
  @override
  String toString() => 'SSH connection attempt was cancelled';
}

class HostKeyVerifier {
  factory HostKeyVerifier({
    required ServerProfile profile,
    required HostKeyConfirmation onFirstUseHostKey,
    Future<void> Function(ServerProfile profile)? persistProfile,
  }) => HostKeyVerifier._(profile, onFirstUseHostKey, persistProfile);
  HostKeyVerifier._(
    this._profile,
    this._onFirstUseHostKey,
    this._persistProfile,
  );
  ServerProfile _profile;
  final HostKeyConfirmation _onFirstUseHostKey;
  final Future<void> Function(ServerProfile profile)? _persistProfile;
  ServerProfile get profile => _profile;

  Future<bool> verify(String keyType, String fingerprint) async {
    final pinnedType = _profile.hostKeyType;
    final pinnedFingerprint = _profile.hostKeyFingerprint;
    if ((pinnedType == null) != (pinnedFingerprint == null)) {
      throw StateError(
        'Pinned host key type and fingerprint must be set together',
      );
    }
    if (pinnedType != null && pinnedFingerprint != null) {
      if (pinnedType != keyType || pinnedFingerprint != fingerprint) {
        throw HostKeyMismatchException(
          host: _profile.host,
          port: _profile.port,
          expectedType: pinnedType,
          expectedFingerprint: pinnedFingerprint,
          actualType: keyType,
          actualFingerprint: fingerprint,
        );
      }
      return true;
    }
    final accepted = await _onFirstUseHostKey(
      HostKeyCandidate(
        host: _profile.host,
        port: _profile.port,
        keyType: keyType,
        fingerprint: fingerprint,
      ),
    );
    if (!accepted) return false;
    final pinned = _profile.copyWith(
      hostKeyType: keyType,
      hostKeyFingerprint: fingerprint,
    );
    await _persistProfile?.call(pinned);
    _profile = pinned;
    return true;
  }
}

class SshConnection implements SshTransport {
  factory SshConnection({
    required ServerProfile profile,
    required ServerSecret secret,
    ServerRepository? repository,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration authTimeout = const Duration(seconds: 15),
    SshDriverFactory driverFactory = const DartSshDriverFactory(),
  }) => SshConnection._(
    profile,
    secret,
    repository,
    connectTimeout,
    authTimeout,
    driverFactory,
  );
  SshConnection._(
    this._profile,
    this.secret,
    this.repository,
    this.connectTimeout,
    this.authTimeout,
    this.driverFactory,
  );

  static const _tmuxPrefix = 'pocket-agent-term-';
  ServerProfile _profile;
  final ServerSecret secret;
  final ServerRepository? repository;
  final Duration connectTimeout;
  final Duration authTimeout;
  final SshDriverFactory driverFactory;
  final StreamController<SshConnectionState> _stateController =
      StreamController<SshConnectionState>.broadcast();
  SshConnectionDriver? _driver;
  SshConnectionState _state = SshConnectionState.disconnected;
  int _generation = 0;

  @override
  ServerProfile get profile => _profile;
  SshConnectionState get state => _state;
  Stream<SshConnectionState> get states => _stateController.stream;
  @override
  bool get isConnected =>
      _state == SshConnectionState.connected && !(_driver?.isClosed ?? true);

  Future<void> connect({required HostKeyConfirmation onFirstUseHostKey}) async {
    if (_state == SshConnectionState.connecting ||
        _state == SshConnectionState.disconnecting) {
      throw StateError('SSH connection is busy');
    }
    if (isConnected) return;
    _validateProfileAndSecret();
    final generation = ++_generation;
    _setState(SshConnectionState.connecting);
    final verifier = HostKeyVerifier(
      profile: _profile,
      onFirstUseHostKey: onFirstUseHostKey,
      persistProfile: repository?.saveProfile,
    );
    SshConnectionDriver? attemptDriver;
    try {
      final driver = await driverFactory.create(
        profile: _profile,
        secret: secret,
        verifyHostKey: (type, fingerprint) async {
          final accepted = await verifier.verify(type, fingerprint);
          if (!accepted) throw const HostKeyRejectedException();
          return true;
        },
        connectTimeout: connectTimeout,
        authTimeout: authTimeout,
      );
      attemptDriver = driver;
      if (!_isCurrentAttempt(generation)) {
        await driver.close();
        throw const SshConnectionCancelledException();
      }
      _driver = driver;
      await driver.authenticated;
      if (!_isCurrentAttempt(generation)) {
        throw const SshConnectionCancelledException();
      }
      _profile = verifier.profile;
      _setState(SshConnectionState.connected);
      unawaited(
        driver.done.then(
          (_) => _handleDriverClosed(driver),
          onError: (_) => _handleDriverClosed(driver, failed: true),
        ),
      );
    } catch (error, stackTrace) {
      if (identical(_driver, attemptDriver)) {
        try {
          await _closeTransport();
        } catch (_) {
          // Preserve the connection or verification failure that triggered cleanup.
        }
      }
      if (_generation == generation) _setState(SshConnectionState.failed);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> disconnect() async {
    if (_state == SshConnectionState.disconnected) return;
    _generation += 1;
    _setState(SshConnectionState.disconnecting);
    try {
      await _closeTransport();
    } finally {
      _setState(SshConnectionState.disconnected);
    }
  }

  Future<PtySession> openShell({int columns = 80, int rows = 24}) async {
    final session = await _requireDriver().shell(_pty(columns, rows));
    return PtySession(id: const Uuid().v4(), session: session);
  }

  Future<PtySession> createPersistentShell({
    String? id,
    int columns = 80,
    int rows = 24,
  }) async {
    id ??= const Uuid().v4().replaceAll('-', '').substring(0, 16);
    validatePocketSessionId(id);
    final session = await _requireDriver().execute(
      buildShellCommand('tmux', ['new-session', '-A', '-s', '$_tmuxPrefix$id']),
      _pty(columns, rows),
    );
    return PtySession(id: id, session: session);
  }

  Future<List<PersistentShell>> listPersistentShells() async {
    final result = await executeCommand('tmux', const [
      'list-sessions',
      '-F',
      '#{session_name}\t#{session_attached}',
    ]);
    if (result.exitCode == 1) return const [];
    if (!result.succeeded) throw StateError('Failed to list persistent shells');
    final shells = <PersistentShell>[];
    for (final line in const LineSplitter().convert(result.stdout)) {
      final fields = line.split('\t');
      if (fields.length != 2 || !fields.first.startsWith(_tmuxPrefix)) continue;
      final id = fields.first.substring(_tmuxPrefix.length);
      if (!RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(id)) continue;
      shells.add(PersistentShell(id: id, attached: fields[1] != '0'));
    }
    return shells;
  }

  Future<PtySession> attachPersistentShell(
    String id, {
    int columns = 80,
    int rows = 24,
  }) async {
    validatePocketSessionId(id);
    final session = await _requireDriver().execute(
      buildShellCommand('tmux', ['attach-session', '-t', '=$_tmuxPrefix$id']),
      _pty(columns, rows),
    );
    return PtySession(id: id, session: session);
  }

  Future<void> deletePersistentShell(String id) async {
    validatePocketSessionId(id);
    final result = await executeCommand('tmux', [
      'kill-session',
      '-t',
      '=$_tmuxPrefix$id',
    ]);
    if (!result.succeeded) {
      throw StateError('Failed to delete persistent shell');
    }
  }

  @override
  Future<RemoteCommandResult> executeCommand(
    String executable,
    Iterable<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final result = await _requireDriver()
        .runWithResult(buildShellCommand(executable, arguments))
        .timeout(timeout);
    return RemoteCommandResult(
      stdout: utf8.decode(result.stdout, allowMalformed: true),
      stderr: utf8.decode(result.stderr, allowMalformed: true),
      exitCode: result.exitCode,
    );
  }

  @override
  Future<SSHForwardChannel> forwardLoopback(int remotePort) {
    if (remotePort < 1 || remotePort > 65535) {
      throw ArgumentError.value(
        remotePort,
        'remotePort',
        'must be a valid port',
      );
    }
    return _requireDriver().forwardLoopback(remotePort);
  }

  SSHPtyConfig _pty(int columns, int rows) {
    if (columns < 1 || rows < 1) {
      throw ArgumentError('Terminal dimensions must be positive');
    }
    return SSHPtyConfig(width: columns, height: rows);
  }

  SshConnectionDriver _requireDriver() {
    final driver = _driver;
    if (!isConnected || driver == null) {
      throw StateError('SSH connection is not connected');
    }
    return driver;
  }

  void _validateProfileAndSecret() {
    if (_profile.id.isEmpty ||
        _profile.name.trim().isEmpty ||
        _profile.host.trim().isEmpty ||
        _profile.username.trim().isEmpty) {
      throw ArgumentError('Server profile fields must not be empty');
    }
    if (_profile.port < 1 || _profile.port > 65535) {
      throw ArgumentError('SSH port must be between 1 and 65535');
    }
    if ((_profile.hostKeyType == null) !=
        (_profile.hostKeyFingerprint == null)) {
      throw ArgumentError('Pinned host key fields must be set together');
    }
    if (_profile.authentication == SshAuthentication.password &&
        !secret.hasPassword) {
      throw ArgumentError('Password authentication requires a password');
    }
    if (_profile.authentication == SshAuthentication.privateKey &&
        !secret.hasPrivateKey) {
      throw ArgumentError('Private-key authentication requires a private key');
    }
  }

  Future<void> _closeTransport() async {
    final driver = _driver;
    _driver = null;
    if (driver != null && !driver.isClosed) await driver.close();
  }

  bool _isCurrentAttempt(int generation) =>
      _generation == generation && _state == SshConnectionState.connecting;

  void _handleDriverClosed(SshConnectionDriver driver, {bool failed = false}) {
    if (!identical(_driver, driver)) return;
    _driver = null;
    if (_state == SshConnectionState.disconnecting) return;
    _setState(
      failed ? SshConnectionState.failed : SshConnectionState.disconnected,
    );
  }

  void _setState(SshConnectionState value) {
    if (_state == value) return;
    _state = value;
    _stateController.add(value);
  }
}

class DartSshDriverFactory implements SshDriverFactory {
  const DartSshDriverFactory();
  @override
  Future<SshConnectionDriver> create({
    required ServerProfile profile,
    required ServerSecret secret,
    required RawHostKeyVerifier verifyHostKey,
    required Duration connectTimeout,
    required Duration authTimeout,
  }) async {
    final identities = profile.authentication == SshAuthentication.privateKey
        ? SSHKeyPair.fromPem(secret.privateKeyPem!, secret.privateKeyPassphrase)
        : null;
    final nativeSocket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: connectTimeout,
    );
    final socket = QueuedSSHSocket(nativeSocket);
    try {
      final client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        onPasswordRequest: profile.authentication == SshAuthentication.password
            ? () => secret.password
            : null,
        onVerifyHostKey: (type, bytes) =>
            verifyHostKey(type, utf8.decode(bytes, allowMalformed: false)),
        handshakeTimeout: connectTimeout,
        authTimeout: authTimeout,
      );
      return DartSshConnectionDriver(socket, client);
    } catch (_) {
      await socket.close();
      rethrow;
    }
  }
}

class DartSshConnectionDriver implements SshConnectionDriver {
  DartSshConnectionDriver(this._socket, this._client);
  final SSHSocket _socket;
  final SSHClient _client;
  @override
  bool get isClosed => _client.isClosed;
  @override
  Future<void> get authenticated => _client.authenticated;
  @override
  Future<void> get done => _client.done;
  @override
  Future<SSHSession> shell(SSHPtyConfig pty) => _client.shell(pty: pty);
  @override
  Future<SSHSession> execute(String command, SSHPtyConfig pty) =>
      _client.execute(command, pty: pty);
  @override
  Future<SSHRunResult> runWithResult(String command) =>
      _client.runWithResult(command);
  @override
  Future<SSHForwardChannel> forwardLoopback(int remotePort) =>
      _client.forwardLocal('127.0.0.1', remotePort);
  @override
  Future<void> close() async {
    if (!_client.isClosed) {
      try {
        await _client.close().timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _socket.destroy();
      }
    } else {
      try {
        await _socket.close().timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _socket.destroy();
      }
    }
  }
}
