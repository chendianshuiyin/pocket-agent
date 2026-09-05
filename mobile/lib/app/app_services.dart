import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import '../codex/codex.dart';
import '../core/server_profile.dart';
import '../core/server_repository.dart';
import '../core/server_secret.dart';
import '../ssh/codex_tunnel.dart';
import '../ssh/pty_session.dart';
import '../ssh/remote_runtime.dart';
import '../ssh/ssh_connection.dart';
import 'app_models.dart';

abstract interface class AppServices {
  Future<List<ServerSummary>> listServers();
  Future<ProfileDraft> loadServerDraft(String id);
  Future<ServerSummary> saveServer(ProfileDraft draft);
  Future<void> deleteServer(String id);
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  });
}

abstract interface class ConnectedServer {
  Stream<LinkSnapshot> get linkStates;
  bool get isConnected;
  Future<ShellHandle> openShell();
  Future<ShellHandle> createPersistentShell(String id);
  Future<List<String>> listPersistentShells();
  Future<ShellHandle> attachPersistentShell(String id);
  Future<void> deletePersistentShell(String id);
  Future<CodexPort> openCodex();
  Future<void> disconnect();
}

abstract interface class CodexPort {
  Stream<CodexWorkspaceSnapshot> get snapshots;
  CodexWorkspaceSnapshot get current;
  Future<void> refreshThreads();
  Future<void> loadMoreThreads();
  Future<void> archiveThread(String id);
  Future<void> createThread({String? cwd});
  Future<void> openThread(String id);
  Future<void> send(String text, {SkillChoice? skill});
  Future<void> runCommand(String command);
  Future<void> selectModel(String model);
  Future<void> interrupt();
  Future<void> decideApproval(ApprovalPrompt prompt, {required bool approved});
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  );
  Future<void> dispose();
}

abstract interface class CodexNavigationPort {
  void showThreadList();
}

void requestCodexThreadList(CodexPort port) {
  if (port case CodexNavigationPort navigation) navigation.showThreadList();
}

class ProductionAppServices implements AppServices {
  ProductionAppServices({Future<ServerRepository>? repository})
    : _repository = repository ?? ServerRepository.create();

  final Future<ServerRepository> _repository;

  @override
  Future<List<ServerSummary>> listServers() async {
    final profiles = await (await _repository).listProfiles();
    return profiles.map(_summary).toList(growable: false);
  }

  @override
  Future<ProfileDraft> loadServerDraft(String id) async {
    final repository = await _repository;
    final profile = await repository.getProfile(id);
    final secret = await repository.getSecret(id);
    if (profile == null) throw StateError('Server profile not found');
    return ProfileDraft(
      id: profile.id,
      name: profile.name,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      authentication: profile.authentication == SshAuthentication.password
          ? AuthenticationKind.password
          : AuthenticationKind.privateKey,
      password: secret?.password ?? '',
      privateKeyPem: secret?.privateKeyPem ?? '',
      privateKeyPassphrase: secret?.privateKeyPassphrase ?? '',
      remoteCodexPort: profile.remoteCodexPort,
    );
  }

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) async {
    final repository = await _repository;
    final old = draft.id == null
        ? null
        : await repository.getProfile(draft.id!);
    final sameHostIdentity =
        old != null && old.host == draft.host.trim() && old.port == draft.port;
    final profile = ServerProfile(
      id: draft.id ?? const Uuid().v4(),
      name: draft.name.trim(),
      host: draft.host.trim(),
      port: draft.port,
      username: draft.username.trim(),
      authentication: draft.authentication == AuthenticationKind.password
          ? SshAuthentication.password
          : SshAuthentication.privateKey,
      hostKeyType: sameHostIdentity ? old.hostKeyType : null,
      hostKeyFingerprint: sameHostIdentity ? old.hostKeyFingerprint : null,
      remoteCodexPort: draft.remoteCodexPort,
    );
    final secret = ServerSecret(
      password: draft.authentication == AuthenticationKind.password
          ? draft.password
          : null,
      privateKeyPem: draft.authentication == AuthenticationKind.privateKey
          ? draft.privateKeyPem
          : null,
      privateKeyPassphrase:
          draft.authentication == AuthenticationKind.privateKey &&
              draft.privateKeyPassphrase.isNotEmpty
          ? draft.privateKeyPassphrase
          : null,
    );
    await repository.save(profile, secret);
    return _summary(profile);
  }

  @override
  Future<void> deleteServer(String id) async => (await _repository).delete(id);

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async {
    final repository = await _repository;
    final profile = await repository.getProfile(id);
    final secret = await repository.getSecret(id);
    if (profile == null || secret == null) {
      throw StateError('Server credentials are incomplete');
    }
    final connection = SshConnection(
      profile: profile,
      secret: secret,
      repository: repository,
    );
    await connection.connect(
      onFirstUseHostKey: (candidate) => confirmHostKey(
        HostKeyPrompt(
          host: candidate.host,
          port: candidate.port,
          keyType: candidate.keyType,
          fingerprint: candidate.fingerprint,
        ),
      ),
    );
    return _ProductionConnectedServer(connection);
  }

  static ServerSummary _summary(ServerProfile profile) => ServerSummary(
    id: profile.id,
    name: profile.name,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authentication: profile.authentication == SshAuthentication.password
        ? AuthenticationKind.password
        : AuthenticationKind.privateKey,
    remoteCodexPort: profile.remoteCodexPort,
    hasPinnedHostKey: profile.hasPinnedHostKey,
  );
}

class _ProductionConnectedServer implements ConnectedServer {
  _ProductionConnectedServer(this._connection);
  final SshConnection _connection;

  @override
  bool get isConnected => _connection.isConnected;

  @override
  Stream<LinkSnapshot> get linkStates => _connection.states.map(
    (state) => LinkSnapshot(switch (state) {
      SshConnectionState.connecting => LinkPhase.connecting,
      SshConnectionState.connected => LinkPhase.connected,
      SshConnectionState.failed => LinkPhase.failed,
      _ => LinkPhase.disconnected,
    }),
  );

  @override
  Future<ShellHandle> openShell() async =>
      _PtyShellHandle(await _connection.openShell());

  @override
  Future<ShellHandle> createPersistentShell(String id) async =>
      _PtyShellHandle(await _connection.createPersistentShell(id: id));

  @override
  Future<List<String>> listPersistentShells() async =>
      (await _connection.listPersistentShells())
          .map((item) => item.id)
          .toList(growable: false);

  @override
  Future<ShellHandle> attachPersistentShell(String id) async =>
      _PtyShellHandle(await _connection.attachPersistentShell(id));

  @override
  Future<void> deletePersistentShell(String id) =>
      _connection.deletePersistentShell(id);

  @override
  Future<CodexPort> openCodex() async {
    final tunnel = await RemoteRuntimeManager(_connection).openTunnel();
    try {
      final client = await CodexClient.connect(
        tunnel.uri,
        headers: tunnel.clientHeaders,
        reconnectPolicy: const ReconnectPolicy(maxAttempts: 3),
      );
      return _ProductionCodexPort(client, tunnel);
    } catch (_) {
      await tunnel.close();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() => _connection.disconnect();
}

class _PtyShellHandle implements ShellHandle {
  const _PtyShellHandle(this._session);
  final PtySession _session;
  @override
  Stream<Uint8List> get output => _session.output;
  @override
  void write(String data) => _session.write(data);
  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) => _session.resize(
    columns,
    rows,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );
  @override
  Future<void> close() => _session.close();
}

@visibleForTesting
CodexPort productionCodexPortForTesting(
  CodexClient client, {
  Future<void> Function()? closeTransport,
}) => _ProductionCodexPort.forTesting(client, closeTransport: closeTransport);

class _ProductionCodexPort implements CodexPort, CodexNavigationPort {
  _ProductionCodexPort(this._client, CodexTunnel tunnel)
    : _closeTransport = tunnel.close {
    _listen();
  }

  _ProductionCodexPort.forTesting(
    this._client, {
    Future<void> Function()? closeTransport,
  }) : _closeTransport = closeTransport ?? _noOpClose {
    _listen();
  }

  void _listen() {
    _subscriptions.add(_client.itemSnapshots.listen(_onItem));
    _subscriptions.add(_client.turnSnapshots.listen(_onTurn));
    _subscriptions.add(_client.threadSnapshots.listen(_onThread));
    _subscriptions.add(_client.serverRequests.listen(_onServerRequest));
    _subscriptions.add(_client.notifications.listen(_onNotification));
    _subscriptions.add(_client.states.listen(_onConnection));
  }

  final CodexClient _client;
  final Future<void> Function() _closeTransport;
  final _controller = StreamController<CodexWorkspaceSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, TimelineItem> _items = {};
  CodexWorkspaceSnapshot _current = const CodexWorkspaceSnapshot();
  CodexThread? _activeThread;
  CodexTurn? _activeTurn;
  String? _selectedModel;
  bool _threadListVisible = false;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _controller.stream;
  @override
  CodexWorkspaceSnapshot get current => _current;

  void _emit(CodexWorkspaceSnapshot value) {
    _current = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  @override
  Future<void> refreshThreads() async {
    _emit(_current.copyWith(loading: true, clearError: true));
    try {
      final account = await _client.readAccount();
      _emit(
        _current.copyWith(
          accountState: account.isAuthenticated
              ? RemoteAccountState.authenticated
              : RemoteAccountState.signedOut,
          accountKind: account.kind.name,
        ),
      );
      final results = await Future.wait<Object>([
        _client.listThreads(limit: 100),
        _client.listSkills(),
        _client.listModels(),
      ]);
      final page = results[0] as Page<CodexThread>;
      final groups = results[1] as List<SkillGroup>;
      final models = results[2] as Page<ModelInfo>;
      final defaults = models.data.where((model) => model.isDefault).toList();
      _selectedModel ??= defaults.isNotEmpty
          ? defaults.first.model
          : models.data.isEmpty
          ? null
          : models.data.first.model;
      _emit(
        _current.copyWith(
          connected: true,
          loading: false,
          threads: page.data.map(_threadSummary).toList(growable: false),
          nextThreadCursor: page.nextCursor,
          clearNextThreadCursor: page.nextCursor == null,
          skills: groups
              .expand((group) => group.skills)
              .where((skill) => skill.enabled)
              .map(
                (skill) => SkillChoice(
                  name: skill.name,
                  path: skill.path,
                  description: skill.description,
                ),
              )
              .toList(growable: false),
          models: models.data
              .where((model) => !model.hidden)
              .map(
                (model) => ModelChoice(
                  id: model.model,
                  label: model.displayName,
                  description: model.description,
                ),
              )
              .toList(growable: false),
          activeModel: _selectedModel,
        ),
      );
    } catch (_) {
      _emit(_current.copyWith(loading: false, error: '任务列表加载失败，请手动重试。'));
    }
  }

  @override
  Future<void> loadMoreThreads() async {
    final cursor = _current.nextThreadCursor;
    if (cursor == null || _current.loading || _current.loadingMoreThreads) {
      return;
    }
    _emit(_current.copyWith(loadingMoreThreads: true, clearError: true));
    try {
      final page = await _client.listThreads(cursor: cursor, limit: 100);
      final byId = <String, ThreadSummary>{
        for (final thread in _current.threads) thread.id: thread,
      };
      for (final thread in page.data.map(_threadSummary)) {
        byId[thread.id] = thread;
      }
      _emit(
        _current.copyWith(
          loadingMoreThreads: false,
          threads: byId.values.toList(growable: false),
          nextThreadCursor: page.nextCursor,
          clearNextThreadCursor: page.nextCursor == null,
        ),
      );
    } catch (_) {
      _emit(
        _current.copyWith(loadingMoreThreads: false, error: '更多任务加载失败，请重试。'),
      );
    }
  }

  @override
  Future<void> archiveThread(String id) async {
    ThreadSummary? summary;
    for (final thread in _current.threads) {
      if (thread.id == id) {
        summary = thread;
        break;
      }
    }
    if (summary?.state == ThreadRunState.running ||
        (id == _current.activeThreadId &&
            (_current.runState == ThreadRunState.running ||
                _current.runState == ThreadRunState.waitingApproval))) {
      _emit(_current.copyWith(error: '运行中的任务不能归档，请先中断任务。'));
      return;
    }
    try {
      await _client.archiveThread(id);
      if (_activeThread?.id == id) {
        _activeThread = null;
        _activeTurn = null;
        _items.clear();
        _emit(
          _current.copyWith(
            clearActiveThread: true,
            timeline: const [],
            runState: ThreadRunState.idle,
            clearApproval: true,
            clearUserInput: true,
          ),
        );
      }
      await refreshThreads();
    } catch (_) {
      _emit(_current.copyWith(error: '任务归档失败，请重试。'));
    }
  }

  @override
  Future<void> createThread({String? cwd}) async {
    _threadListVisible = false;
    _emit(_current.copyWith(loading: true, clearError: true));
    try {
      final thread = await _client.startThread(cwd: cwd, model: _selectedModel);
      _setActiveThread(thread);
      await refreshThreads();
    } catch (_) {
      _emit(_current.copyWith(loading: false, error: '创建任务失败，请重试。'));
    }
  }

  @override
  Future<void> openThread(String id) async {
    _threadListVisible = false;
    _emit(_current.copyWith(loading: true, clearError: true));
    try {
      _setActiveThread(await _client.openThread(id));
    } catch (_) {
      _emit(_current.copyWith(loading: false, error: '任务打开失败，请重试。'));
    }
  }

  void _setActiveThread(CodexThread thread) {
    _activeThread = thread;
    final threadModel = thread.raw['model'];
    if (threadModel is String && threadModel.isNotEmpty) {
      _selectedModel = threadModel;
    }
    _activeTurn = thread.turns.isEmpty ? null : thread.turns.last;
    _items.clear();
    for (final turn in thread.turns) {
      for (final item in turn.items) {
        final mapped = codexItemToTimeline(item, completed: true);
        _items[mapped.id] = mapped;
      }
    }
    final presentation = codexTurnPresentation(_activeTurn);
    _emit(
      _current.copyWith(
        loading: false,
        activeThreadId: thread.id,
        clearActiveThread: _threadListVisible,
        timeline: _threadListVisible
            ? const []
            : _items.values.toList(growable: false),
        runState: presentation.state,
        error: presentation.error,
        clearError: presentation.error == null,
        activeModel: _selectedModel,
        clearApproval: true,
        clearUserInput: true,
      ),
    );
  }

  @override
  void showThreadList() {
    _threadListVisible = true;
    _emit(_current.copyWith(clearActiveThread: true, timeline: const []));
  }

  @override
  Future<void> send(String text, {SkillChoice? skill}) async {
    if (text.trim().isEmpty && skill == null) return;
    if (_activeThread == null) {
      await createThread();
      if (_activeThread == null) return;
    }
    final input = <CodexInput>[
      if (skill != null) CodexInput.skill(name: skill.name, path: skill.path),
      if (text.trim().isNotEmpty || skill != null)
        CodexInput.text(
          skill == null
              ? text.trim()
              : '\$${skill.name}${text.trim().isEmpty ? '' : ' ${text.trim()}'}',
        ),
    ];
    _emit(
      _current.copyWith(runState: ThreadRunState.running, clearError: true),
    );
    try {
      _activeTurn = await _client.startTurn(
        _activeThread!.id,
        input,
        model: _selectedModel,
      );
    } catch (_) {
      _emit(
        _current.copyWith(runState: ThreadRunState.error, error: '消息发送失败，请重试。'),
      );
    }
  }

  @override
  Future<void> runCommand(String command) async {
    final thread = _activeThread;
    if (thread == null) return;
    try {
      switch (command) {
        case '/review':
          await _client.reviewUncommittedChanges(thread.id);
        case '/compact':
          await _client.compactThread(thread.id);
        case '/status':
          final refreshed = await _client.readThread(
            thread.id,
            includeTurns: true,
          );
          _setActiveThread(refreshed);
      }
    } catch (_) {
      _emit(
        _current.copyWith(error: '命令执行失败，请重试。', runState: ThreadRunState.error),
      );
    }
  }

  @override
  Future<void> selectModel(String model) async {
    _selectedModel = model;
    _emit(_current.copyWith(activeModel: model, clearError: true));
    final thread = _activeThread;
    if (thread == null) return;
    try {
      _activeThread = await _client.resumeThread(thread.id, model: model);
    } catch (_) {
      _emit(_current.copyWith(error: '模型切换失败，请重试。'));
    }
  }

  @override
  Future<void> interrupt() async {
    final thread = _activeThread;
    final turn = _activeTurn;
    if (thread == null || turn == null) return;
    if (!await _client.interruptTurn(thread.id, turn.id)) return;
    if (!identical(_activeThread, thread) || !identical(_activeTurn, turn)) {
      return;
    }
    _emit(
      _current.copyWith(
        runState: ThreadRunState.idle,
        clearApproval: true,
        clearUserInput: true,
      ),
    );
  }

  void _onItem(ItemSnapshot snapshot) {
    if (snapshot.threadId != _activeThread?.id) return;
    final item = codexItemToTimeline(
      snapshot.item,
      completed: snapshot.completed,
    );
    _items[item.id] = item;
    _emit(
      _current.copyWith(
        timeline: _items.values.toList(growable: false),
        runState: snapshot.completed
            ? _current.runState
            : ThreadRunState.running,
      ),
    );
  }

  void _onTurn(TurnSnapshot snapshot) {
    if (snapshot.threadId != _activeThread?.id) return;
    if (snapshot.completed &&
        _activeTurn != null &&
        snapshot.turn.id != _activeTurn!.id) {
      return;
    }
    _activeTurn = snapshot.turn;
    final presentation = codexTurnPresentation(snapshot.turn);
    final approvalRequest = _current.approval?.raw;
    final userInputRequest = _current.userInput?.raw;
    final clearApproval =
        snapshot.completed &&
        approvalRequest is ServerRequest &&
        approvalRequest.threadId == snapshot.threadId &&
        approvalRequest.turnId == snapshot.turn.id;
    final clearUserInput =
        snapshot.completed &&
        userInputRequest is ServerRequest &&
        userInputRequest.threadId == snapshot.threadId &&
        userInputRequest.turnId == snapshot.turn.id;
    _emit(
      _current.copyWith(
        runState: presentation.state,
        error: presentation.error,
        clearError: presentation.error == null,
        clearApproval: clearApproval,
        clearUserInput: clearUserInput,
      ),
    );
  }

  void _onThread(ThreadSnapshot snapshot) {
    if (snapshot.recovered && snapshot.thread.id == _activeThread?.id) {
      _setActiveThread(snapshot.thread);
    }
  }

  void _onConnection(ConnectionSnapshot snapshot) {
    final connected = snapshot.phase == ConnectionPhase.ready;
    _emit(
      _current.copyWith(
        connected: connected,
        clearError: connected,
        error: snapshot.phase == ConnectionPhase.disconnected
            ? 'Codex 连接已断开，请手动重连。'
            : null,
        clearApproval: !connected,
        clearUserInput: !connected,
      ),
    );
  }

  void _onServerRequest(ServerRequest request) {
    routeMobileServerRequest(
      request,
      activeThreadId: _activeThread?.id,
      reject: (request, message) =>
          _client.rejectServerRequest(request, message: message),
      showUserInput: (prompt) => _emit(
        _current.copyWith(
          runState: ThreadRunState.waitingApproval,
          userInput: prompt,
        ),
      ),
      showApproval: (prompt) => _emit(
        _current.copyWith(
          runState: ThreadRunState.waitingApproval,
          approval: prompt,
        ),
      ),
    );
  }

  void _onNotification(RpcNotification notification) {
    if (notification.method != 'serverRequest/resolved') return;
    final requestId = notification.params['requestId'];
    final threadId = jsonString(notification.params['threadId']);
    final approvalRequest = _current.approval?.raw;
    final userInputRequest = _current.userInput?.raw;
    final clearApproval =
        approvalRequest is ServerRequest &&
        approvalRequest.id == requestId &&
        (threadId == null || approvalRequest.threadId == threadId);
    final clearUserInput =
        userInputRequest is ServerRequest &&
        userInputRequest.id == requestId &&
        (threadId == null || userInputRequest.threadId == threadId);
    if (!clearApproval && !clearUserInput) return;
    _emit(
      _current.copyWith(
        clearApproval: clearApproval,
        clearUserInput: clearUserInput,
        runState: ThreadRunState.running,
      ),
    );
  }

  @override
  Future<void> decideApproval(
    ApprovalPrompt prompt, {
    required bool approved,
  }) async {
    if (!identical(_current.approval, prompt)) return;
    final responded = _client.respondApproval(
      prompt.raw as ServerRequest,
      approved ? ApprovalDecision.accept : ApprovalDecision.decline,
    );
    if (!responded || !identical(_current.approval, prompt)) return;
    _emit(
      _current.copyWith(runState: ThreadRunState.running, clearApproval: true),
    );
  }

  @override
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  ) async {
    if (!identical(_current.userInput, prompt)) return;
    final responded = _client.respondUserInput(
      prompt.raw as ServerRequest,
      answers,
    );
    if (!responded || !identical(_current.userInput, prompt)) return;
    _emit(
      _current.copyWith(runState: ThreadRunState.running, clearUserInput: true),
    );
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _client.dispose();
    await _closeTransport();
    await _controller.close();
  }

  static Future<void> _noOpClose() async {}

  static ThreadSummary _threadSummary(CodexThread thread) => ThreadSummary(
    id: thread.id,
    title: (thread.name?.trim().isNotEmpty ?? false) ? thread.name! : '未命名任务',
    preview: thread.preview.trim(),
    updatedAt: thread.updatedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(thread.updatedAt! * 1000),
    state: thread.status.type == 'active'
        ? ThreadRunState.running
        : ThreadRunState.idle,
  );
}

({ThreadRunState state, String? error}) codexTurnPresentation(CodexTurn? turn) {
  final state = switch (turn?.status) {
    'inProgress' => ThreadRunState.running,
    'failed' => ThreadRunState.error,
    'completed' => ThreadRunState.completed,
    _ => ThreadRunState.idle,
  };
  if (state != ThreadRunState.error) return (state: state, error: null);
  final rawError = turn?.error;
  final message = rawError is Map
      ? jsonString(jsonMap(rawError)['message'])
      : rawError is String
      ? rawError
      : null;
  final trimmed = message?.trim() ?? '';
  if (trimmed.isEmpty) {
    return (state: state, error: '任务运行失败，请重试。');
  }
  final bounded = String.fromCharCodes(trimmed.runes.take(600));
  return (state: state, error: '任务运行失败：$bounded');
}

TimelineItem codexItemToTimeline(CodexItem item, {required bool completed}) {
  final type = item.type.toLowerCase();
  final kind = type.contains('user')
      ? TimelineKind.user
      : type.contains('reason')
      ? TimelineKind.reasoning
      : type.contains('tool') ||
            type.contains('command') ||
            type.contains('change')
      ? TimelineKind.tool
      : type.contains('error')
      ? TimelineKind.error
      : TimelineKind.assistant;
  return TimelineItem(
    id: item.id ?? '${item.type}-${item.hashCode}',
    kind: kind,
    title: kind == TimelineKind.tool ? _toolTitle(item.data) : null,
    text: _itemDisplayText(item.data),
    inProgress: !completed,
  );
}

String _itemDisplayText(JsonMap data) {
  final aggregatedOutput = jsonString(data['aggregatedOutput']);
  if (aggregatedOutput != null && aggregatedOutput.trim().isNotEmpty) {
    return aggregatedOutput;
  }
  final changes = _currentFileChanges(data['changes']);
  if (changes.isNotEmpty) return changes;
  final legacyChanges = _legacyFileChanges(data['fileChanges']);
  if (legacyChanges.isNotEmpty) return legacyChanges;
  for (final key in const ['text', 'output', 'message', 'content', 'summary']) {
    final value = data[key];
    final text = _textContent(value);
    if (text.isNotEmpty) return text;
  }
  final result = jsonMap(data['result']);
  final resultText = _textContent(result['content']);
  if (resultText.isNotEmpty) return resultText;
  final dynamicOutput = _textContent(data['contentItems']);
  if (dynamicOutput.isNotEmpty) return dynamicOutput;
  final errorMessage = jsonString(jsonMap(data['error'])['message']);
  if (errorMessage != null && errorMessage.trim().isNotEmpty) {
    return errorMessage;
  }
  return '状态已更新';
}

String _currentFileChanges(Object? value) {
  final lines = <String>[];
  for (final entry in jsonList(value)) {
    final change = jsonMap(entry);
    final path = jsonString(change['path']);
    if (path == null || path.isEmpty) continue;
    final kind = jsonString(jsonMap(change['kind'])['type']) ?? '更新';
    final movePath = jsonString(jsonMap(change['kind'])['move_path']);
    final diff = jsonString(change['diff']) ?? '';
    lines.add(
      [
        '$kind $path${movePath == null ? '' : ' -> $movePath'}',
        if (diff.trim().isNotEmpty) diff,
      ].join('\n'),
    );
  }
  return lines.join('\n\n');
}

String _legacyFileChanges(Object? value) {
  if (value is! Map) return '';
  final lines = <String>[];
  for (final entry in value.entries) {
    if (entry.key is! String) continue;
    final change = jsonMap(entry.value);
    final kind = jsonString(change['type']) ?? '更新';
    final movePath = jsonString(change['move_path']);
    final diff =
        jsonString(change['unified_diff']) ??
        jsonString(change['content']) ??
        '';
    lines.add(
      [
        '$kind ${entry.key as String}${movePath == null ? '' : ' -> $movePath'}',
        if (diff.trim().isNotEmpty) diff,
      ].join('\n'),
    );
  }
  return lines.join('\n\n');
}

String _textContent(Object? value) {
  if (value is String) return value.trim().isEmpty ? '' : value;
  if (value is! List) return '';
  return value
      .map((part) => part is Map ? part['text'] : part)
      .whereType<String>()
      .where((text) => text.trim().isNotEmpty)
      .join('\n');
}

String _toolTitle(JsonMap data) =>
    jsonString(data['name']) ?? jsonString(data['command']) ?? '工具调用';

typedef RejectMobileServerRequest = void Function(
  ServerRequest request,
  String message,
);

void routeMobileServerRequest(
  ServerRequest request, {
  required String? activeThreadId,
  required RejectMobileServerRequest reject,
  required void Function(UserInputPrompt prompt) showUserInput,
  required void Function(ApprovalPrompt prompt) showApproval,
}) {
  if (request.threadId != null && request.threadId != activeThreadId) {
    reject(request, 'Request belongs to an inactive thread');
    return;
  }
  const userInputMethods = {
    'item/tool/requestUserInput',
    'tool/requestUserInput',
  };
  if (userInputMethods.contains(request.method)) {
    final questions = jsonList(request.params['questions'])
        .map(jsonMap)
        .map((question) {
          final options = jsonList(question['options'])
              .map(jsonMap)
              .map((option) => jsonString(option['label']))
              .whereType<String>()
              .toList(growable: false);
          return UserInputQuestion(
            id: jsonString(question['id']) ?? '',
            prompt:
                jsonString(question['question']) ??
                jsonString(question['header']) ??
                '请输入回复',
            options: options,
          );
        })
        .where((question) => question.id.isNotEmpty)
        .toList(growable: false);
    if (questions.isEmpty) {
      reject(request, 'User-input request has no valid questions');
      return;
    }
    showUserInput(UserInputPrompt(questions: questions, raw: request));
    return;
  }
  const approvalMethods = {
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
  };
  if (!approvalMethods.contains(request.method)) {
    reject(request, 'Pocket Agent Mobile does not support this request type');
    return;
  }
  final value =
      request.params['command'] ??
      request.params['reason'] ??
      request.params['description'];
  showApproval(
    ApprovalPrompt(
      id: request.id.toString(),
      title: request.method.toLowerCase().contains('command')
          ? '允许执行命令？'
          : '允许修改文件？',
      details: value?.toString() ?? '远程任务请求继续执行敏感操作。',
      raw: request,
    ),
  );
}
