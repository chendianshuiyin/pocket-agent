import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_models.dart';
import 'app_services.dart';

typedef HostKeyConfirmer = Future<bool> Function(HostKeyPrompt prompt);

class PocketController extends ChangeNotifier {
  PocketController(this.services);

  final AppServices services;
  List<ServerSummary> servers = const [];
  bool loading = true;
  String? error;
  String? activeServerId;
  final Map<String, ServerWorkspace> _workspaces = {};
  int _generation = 0;
  bool _disposed = false;

  ServerWorkspace? get activeWorkspace =>
      activeServerId == null ? null : _workspaces[activeServerId];

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> initialize() async {
    if (_disposed) return;
    await refreshServers();
  }

  Future<void> refreshServers() async {
    if (_disposed) return;
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await services.listServers();
      if (!_isCurrent(generation)) return;
      servers = result;
      if (activeServerId != null &&
          !servers.any((server) => server.id == activeServerId)) {
        activeServerId = null;
      }
    } catch (_) {
      if (!_isCurrent(generation)) return;
      error = '无法读取服务器，请稍后重试。';
    } finally {
      if (_isCurrent(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<ServerSummary?> save(ProfileDraft draft) async {
    if (_disposed) return null;
    final generation = _generation;
    try {
      final result = await services.saveServer(draft);
      if (!_isCurrent(generation)) return null;
      if (draft.id != null) {
        final workspace = _workspaces.remove(draft.id!);
        await workspace?.shutdown();
        workspace?.dispose();
        if (!_isCurrent(generation)) return null;
        if (activeServerId == draft.id) activeServerId = null;
      }
      await refreshServers();
      return _isCurrent(generation) ? result : null;
    } catch (_) {
      if (_isCurrent(generation)) {
        error = '保存失败，请检查输入与安全存储状态。';
        notifyListeners();
      }
      return null;
    }
  }

  Future<bool> deleteServer(String id) async {
    if (_disposed) return false;
    final generation = _generation;
    try {
      final workspace = _workspaces.remove(id);
      await workspace?.shutdown();
      workspace?.dispose();
      if (!_isCurrent(generation)) return false;
      await services.deleteServer(id);
      if (!_isCurrent(generation)) return false;
      await refreshServers();
      return _isCurrent(generation);
    } catch (_) {
      if (_isCurrent(generation)) {
        error = '删除失败，请重试。';
        notifyListeners();
      }
      return false;
    }
  }

  Future<ServerWorkspace?> openServer(
    ServerSummary server,
    HostKeyConfirmer confirmHostKey,
  ) async {
    if (_disposed) return null;
    final generation = _generation;
    activeServerId = server.id;
    final existing = _workspaces[server.id];
    if (existing != null) {
      notifyListeners();
      return existing;
    }
    final workspace = ServerWorkspace(server: server, services: services);
    _workspaces[server.id] = workspace;
    notifyListeners();
    final connected = await workspace.connect(confirmHostKey);
    if (!_isCurrent(generation) || _workspaces[server.id] != workspace) {
      await workspace.shutdown();
      workspace.dispose();
      return null;
    }
    notifyListeners();
    return connected ? workspace : null;
  }

  void closeServerView() {
    if (_disposed) return;
    activeServerId = null;
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _generation += 1;
    final workspaces = _workspaces.values.toList(growable: false);
    _workspaces.clear();
    activeServerId = null;
    for (final workspace in workspaces) {
      await workspace.shutdown();
      workspace.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    final workspaces = _workspaces.values.toList(growable: false);
    _workspaces.clear();
    activeServerId = null;
    for (final workspace in workspaces) {
      workspace.dispose();
    }
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}

class ServerWorkspace extends ChangeNotifier {
  ServerWorkspace({required this.server, required this.services});

  final ServerSummary server;
  final AppServices services;
  ConnectedServer? connection;
  LinkSnapshot link = const LinkSnapshot(LinkPhase.disconnected);
  String? error;
  bool busy = false;
  int selectedFeature = 0;
  final List<TerminalSessionModel> terminals = [];
  int selectedTerminal = 0;
  CodexPort? codex;
  CodexWorkspaceSnapshot codexSnapshot = const CodexWorkspaceSnapshot();
  StreamSubscription<LinkSnapshot>? _linkSubscription;
  StreamSubscription<CodexWorkspaceSnapshot>? _codexSubscription;
  String? _codexThreadToRestore;
  int _generation = 0;
  bool _disposed = false;

  bool get connected => connection?.isConnected ?? false;
  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<bool> connect(HostKeyConfirmer confirmHostKey) async {
    if (_disposed || busy) return false;
    final generation = ++_generation;
    busy = true;
    error = null;
    link = const LinkSnapshot(LinkPhase.connecting);
    notifyListeners();
    try {
      await _linkSubscription?.cancel();
      if (!_isCurrent(generation)) return false;
      final openedConnection = await services.connectServer(
        server.id,
        confirmHostKey: confirmHostKey,
      );
      if (!_isCurrent(generation)) {
        await openedConnection.disconnect();
        return false;
      }
      connection = openedConnection;
      _linkSubscription = openedConnection.linkStates.listen((value) {
        if (_disposed || connection != openedConnection) return;
        link = value;
        notifyListeners();
      });
      link = const LinkSnapshot(LinkPhase.connected);
      return true;
    } catch (_) {
      if (!_isCurrent(generation)) return false;
      link = const LinkSnapshot(LinkPhase.failed);
      error = '连接失败。若主机密钥已变化，连接已为保护你而阻止。';
      return false;
    } finally {
      if (_isCurrent(generation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> reconnect(HostKeyConfirmer confirmHostKey) async {
    if (_disposed || busy) return false;
    _codexThreadToRestore = codexSnapshot.activeThreadId;
    await _disposeConnection(preserveTerminals: false);
    return connect(confirmHostKey);
  }

  void selectFeature(int value) {
    if (_disposed) return;
    selectedFeature = value;
    notifyListeners();
  }

  void showCodexThreadList() {
    if (_disposed) return;
    final activeCodex = codex;
    if (activeCodex != null) requestCodexThreadList(activeCodex);
    codexSnapshot = codexSnapshot.copyWith(
      clearActiveThread: true,
      timeline: const [],
    );
    notifyListeners();
  }

  Future<void> openTerminal({bool persistent = false, String? id}) async {
    final activeConnection = connection;
    if (_disposed || activeConnection == null || !connected || busy) return;
    final generation = _generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final handle = persistent
          ? await activeConnection.createPersistentShell(id ?? 'main')
          : await activeConnection.openShell();
      if (!_isCurrent(generation) ||
          connection != activeConnection ||
          !activeConnection.isConnected) {
        await handle.close();
        return;
      }
      final session = TerminalSessionModel(
        id: id ?? 'shell-${DateTime.now().microsecondsSinceEpoch}',
        title: persistent ? (id ?? 'main') : '终端 ${terminals.length + 1}',
        persistent: persistent,
        handle: handle,
      );
      terminals.add(session);
      selectedTerminal = terminals.length - 1;
    } catch (_) {
      if (_isCurrent(generation)) {
        error = persistent ? '无法创建持久终端。' : '无法打开终端。';
      }
    } finally {
      if (_isCurrent(generation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<List<String>> listPersistentShells() async {
    final activeConnection = connection;
    if (_disposed || activeConnection == null || !connected) return const [];
    final generation = _generation;
    final result = await activeConnection.listPersistentShells();
    return _isCurrent(generation) &&
            connection == activeConnection &&
            activeConnection.isConnected
        ? result
        : const [];
  }

  Future<void> attachPersistentShell(String id) async {
    if (_disposed) return;
    final existing = terminals.indexWhere(
      (terminal) => terminal.persistent && terminal.id == id,
    );
    if (existing >= 0) {
      selectedTerminal = existing;
      notifyListeners();
      return;
    }
    final activeConnection = connection;
    if (activeConnection == null || !connected) return;
    final generation = _generation;
    busy = true;
    notifyListeners();
    try {
      final handle = await activeConnection.attachPersistentShell(id);
      if (!_isCurrent(generation) ||
          connection != activeConnection ||
          !activeConnection.isConnected) {
        await handle.close();
        return;
      }
      terminals.add(
        TerminalSessionModel(
          id: id,
          title: id,
          persistent: true,
          handle: handle,
        ),
      );
      selectedTerminal = terminals.length - 1;
    } catch (_) {
      if (_isCurrent(generation)) error = '无法附加持久终端。';
    } finally {
      if (_isCurrent(generation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> deletePersistentShell(String id) async {
    if (_disposed) return;
    final activeConnection = connection;
    final generation = _generation;
    await activeConnection?.deletePersistentShell(id);
    if (!_isCurrent(generation) ||
        connection != activeConnection ||
        activeConnection?.isConnected != true) {
      return;
    }
    final index = terminals.indexWhere((terminal) => terminal.id == id);
    if (index >= 0) await closeTerminal(index);
  }

  Future<void> closeTerminal(int index) async {
    if (_disposed) return;
    if (index < 0 || index >= terminals.length) return;
    final terminal = terminals.removeAt(index);
    selectedTerminal = terminals.isEmpty
        ? 0
        : selectedTerminal.clamp(0, terminals.length - 1);
    notifyListeners();
    await terminal.dispose();
  }

  void selectTerminal(int index) {
    if (_disposed || index < 0 || index >= terminals.length) return;
    selectedTerminal = index;
    notifyListeners();
  }

  Future<void> openCodex() async {
    if (codex != null) return;
    final activeConnection = connection;
    if (_disposed || activeConnection == null || !connected || busy) return;
    final generation = _generation;
    busy = true;
    error = null;
    codexSnapshot = codexSnapshot.copyWith(loading: true, clearError: true);
    notifyListeners();
    try {
      final openedCodex = await activeConnection.openCodex();
      if (!_isCurrent(generation) ||
          connection != activeConnection ||
          !activeConnection.isConnected) {
        await openedCodex.dispose();
        return;
      }
      codex = openedCodex;
      _codexSubscription = openedCodex.snapshots.listen((value) {
        if (!_isCurrent(generation) || codex != openedCodex) return;
        codexSnapshot = value;
        notifyListeners();
      });
      await openedCodex.refreshThreads();
      if (!_isCurrent(generation) || codex != openedCodex) return;
      codexSnapshot = openedCodex.current;
      final restoreId = _codexThreadToRestore;
      if (restoreId != null) {
        await openedCodex.openThread(restoreId);
        if (!_isCurrent(generation) || codex != openedCodex) return;
        codexSnapshot = openedCodex.current;
        _codexThreadToRestore = null;
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        codexSnapshot = codexSnapshot.copyWith(
          loading: false,
          error: 'Codex 服务连接失败。请确认远程 Codex 可用后手动重试。',
        );
      }
    } finally {
      if (_isCurrent(generation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> retryCodex() async {
    if (_disposed || busy) return;
    final restoreId = codexSnapshot.activeThreadId;
    final generation = ++_generation;
    final subscription = _codexSubscription;
    _codexSubscription = null;
    final codexToDispose = codex;
    codex = null;
    await subscription?.cancel();
    await codexToDispose?.dispose();
    if (!_isCurrent(generation)) return;
    _codexThreadToRestore = restoreId;
    await openCodex();
  }

  Future<void> _disposeConnection({required bool preserveTerminals}) async {
    _generation += 1;
    busy = false;
    final codexSubscription = _codexSubscription;
    _codexSubscription = null;
    final codexToDispose = codex;
    codex = null;
    codexSnapshot = const CodexWorkspaceSnapshot();
    final terminalSessions = preserveTerminals
        ? const <TerminalSessionModel>[]
        : terminals.toList(growable: false);
    if (!preserveTerminals) {
      terminals.clear();
      selectedTerminal = 0;
    }
    final linkSubscription = _linkSubscription;
    _linkSubscription = null;
    final connectionToDispose = connection;
    connection = null;
    link = const LinkSnapshot(LinkPhase.disconnected);
    await codexSubscription?.cancel();
    await codexToDispose?.dispose();
    for (final terminal in terminalSessions) {
      await terminal.dispose();
    }
    await linkSubscription?.cancel();
    await connectionToDispose?.disconnect();
  }

  Future<void> shutdown() => _disposeConnection(preserveTerminals: false);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_disposeConnection(preserveTerminals: false));
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
