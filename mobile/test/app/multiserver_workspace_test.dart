import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';

void main() {
  test('different servers can stay connected at the same time', () async {
    final services = _FakeAppServices([serverA, serverB]);
    final controller = PocketController(services);
    await controller.initialize();

    final results = await Future.wait([
      controller.openServer(serverA, _acceptHostKey),
      controller.openServer(serverB, _acceptHostKey),
    ]);
    final workspaceA = results[0]!;
    final workspaceB = results[1]!;

    expect(workspaceA, isNot(same(workspaceB)));
    expect(workspaceA.connected, isTrue);
    expect(workspaceB.connected, isTrue);
    expect(services.connectionsFor('server-a'), hasLength(1));
    expect(services.connectionsFor('server-b'), hasLength(1));
    expect(controller.activeWorkspace, same(workspaceB));

    await controller.shutdown();
    controller.dispose();
  });

  test(
    'switching the visible server keeps the other connection alive',
    () async {
      final services = _FakeAppServices([serverA, serverB]);
      final controller = PocketController(services);
      await controller.initialize();
      final workspaceA = (await controller.openServer(
        serverA,
        _acceptHostKey,
      ))!;
      final workspaceB = (await controller.openServer(
        serverB,
        _acceptHostKey,
      ))!;

      expect(
        await controller.openServer(serverA, _acceptHostKey),
        same(workspaceA),
      );
      expect(controller.activeWorkspace, same(workspaceA));
      expect(workspaceB.connected, isTrue);
      expect(services.latestConnection('server-b').disconnectCalls, 0);

      controller.closeServerView();
      expect(controller.activeWorkspace, isNull);
      expect(workspaceA.connected, isTrue);
      expect(workspaceB.connected, isTrue);

      await controller.shutdown();
      controller.dispose();
    },
  );

  test('same tmux id belongs to separate server workspaces', () async {
    final services = _FakeAppServices([serverA, serverB]);
    final controller = PocketController(services);
    await controller.initialize();
    final workspaceA = (await controller.openServer(serverA, _acceptHostKey))!;
    final workspaceB = (await controller.openServer(serverB, _acceptHostKey))!;

    await Future.wait([
      workspaceA.openTerminal(persistent: true, id: 'main'),
      workspaceB.openTerminal(persistent: true, id: 'main'),
    ]);

    final terminalA = workspaceA.terminals.single;
    final terminalB = workspaceB.terminals.single;
    expect(terminalA.id, 'main');
    expect(terminalB.id, 'main');
    expect(terminalA.handle, isNot(same(terminalB.handle)));
    expect((terminalA.handle as _FakeShellHandle).owner, 'server-a/main');
    expect((terminalB.handle as _FakeShellHandle).owner, 'server-b/main');

    await workspaceA.deletePersistentShell('main');
    expect(workspaceA.terminals, isEmpty);
    expect(workspaceB.terminals.single, same(terminalB));
    expect((terminalA.handle as _FakeShellHandle).closed, isTrue);
    expect((terminalB.handle as _FakeShellHandle).closed, isFalse);

    await controller.shutdown();
    controller.dispose();
  });

  test(
    'background SSH and Codex events do not replace the active workspace state',
    () async {
      final services = _FakeAppServices([serverA, serverB]);
      final controller = PocketController(services);
      await controller.initialize();
      final workspaceA = (await controller.openServer(
        serverA,
        _acceptHostKey,
      ))!;
      final workspaceB = (await controller.openServer(
        serverB,
        _acceptHostKey,
      ))!;
      await Future.wait([workspaceA.openCodex(), workspaceB.openCodex()]);
      final connectionA = services.latestConnection('server-a');
      final connectionB = services.latestConnection('server-b');

      connectionB.codex.emit(_snapshot('thread-b', 'server B'));
      await _flushEvents();
      connectionA.emitLink(
        const LinkSnapshot(LinkPhase.failed, message: 'background failure'),
      );
      connectionA.codex.emit(_snapshot('thread-a', 'server A background'));
      await _flushEvents();

      expect(controller.activeWorkspace, same(workspaceB));
      expect(workspaceA.link.phase, LinkPhase.failed);
      expect(workspaceA.codexSnapshot.activeThreadId, 'thread-a');
      expect(workspaceB.link.phase, LinkPhase.connected);
      expect(workspaceB.codexSnapshot.activeThreadId, 'thread-b');
      expect(workspaceB.codexSnapshot.timeline.single.text, 'server B');

      await controller.shutdown();
      controller.dispose();
    },
  );

  test('editing one server resets only its workspace', () async {
    final services = _FakeAppServices([serverA, serverB]);
    final controller = PocketController(services);
    await controller.initialize();
    final oldWorkspaceA = (await controller.openServer(
      serverA,
      _acceptHostKey,
    ))!;
    final workspaceB = (await controller.openServer(serverB, _acceptHostKey))!;
    await oldWorkspaceA.openTerminal(persistent: true, id: 'main');
    final oldConnectionA = services.latestConnection('server-a');
    final connectionB = services.latestConnection('server-b');

    final saved = await controller.save(_draftFor(serverA, name: 'Alpha 2'));

    expect(saved?.name, 'Alpha 2');
    expect(oldConnectionA.disconnectCalls, 1);
    expect(oldWorkspaceA.connected, isFalse);
    expect(oldWorkspaceA.terminals, isEmpty);
    expect(connectionB.disconnectCalls, 0);
    expect(workspaceB.connected, isTrue);
    expect(controller.activeWorkspace, same(workspaceB));

    final newWorkspaceA = (await controller.openServer(
      saved!,
      _acceptHostKey,
    ))!;
    expect(newWorkspaceA, isNot(same(oldWorkspaceA)));
    expect(newWorkspaceA.terminals, isEmpty);
    expect(services.connectionsFor('server-a'), hasLength(2));

    await controller.shutdown();
    controller.dispose();
  });

  test('deleting one server leaves the other workspace connected', () async {
    final services = _FakeAppServices([serverA, serverB]);
    final controller = PocketController(services);
    await controller.initialize();
    await controller.openServer(serverA, _acceptHostKey);
    final workspaceB = (await controller.openServer(serverB, _acceptHostKey))!;
    final connectionA = services.latestConnection('server-a');
    final connectionB = services.latestConnection('server-b');

    expect(await controller.deleteServer('server-a'), isTrue);

    expect(connectionA.disconnectCalls, 1);
    expect(connectionB.disconnectCalls, 0);
    expect(workspaceB.connected, isTrue);
    expect(controller.activeWorkspace, same(workspaceB));
    expect(controller.servers.map((server) => server.id), ['server-b']);

    await controller.shutdown();
    controller.dispose();
  });

  test('controller shutdown closes every server workspace', () async {
    final services = _FakeAppServices([serverA, serverB]);
    final controller = PocketController(services);
    await controller.initialize();
    final workspaceA = (await controller.openServer(serverA, _acceptHostKey))!;
    final workspaceB = (await controller.openServer(serverB, _acceptHostKey))!;
    await workspaceA.openTerminal(persistent: true, id: 'main');
    await workspaceB.openCodex();
    final connectionA = services.latestConnection('server-a');
    final connectionB = services.latestConnection('server-b');
    final shellA = workspaceA.terminals.single.handle as _FakeShellHandle;

    await controller.shutdown();

    expect(controller.activeWorkspace, isNull);
    expect(connectionA.disconnectCalls, 1);
    expect(connectionB.disconnectCalls, 1);
    expect(shellA.closed, isTrue);
    expect(connectionB.codex.disposed, isTrue);
    expect(workspaceA.connected, isFalse);
    expect(workspaceB.connected, isFalse);
    controller.dispose();
  });
}

const serverA = ServerSummary(
  id: 'server-a',
  name: 'Alpha',
  host: 'alpha.test',
  port: 22,
  username: 'alpha',
  authentication: AuthenticationKind.password,
  remoteCodexPort: 4500,
  hasPinnedHostKey: true,
);

const serverB = ServerSummary(
  id: 'server-b',
  name: 'Beta',
  host: 'beta.test',
  port: 2222,
  username: 'beta',
  authentication: AuthenticationKind.privateKey,
  remoteCodexPort: 4600,
  hasPinnedHostKey: true,
);

Future<bool> _acceptHostKey(HostKeyPrompt _) async => true;

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

CodexWorkspaceSnapshot _snapshot(String threadId, String text) =>
    CodexWorkspaceSnapshot(
      connected: true,
      activeThreadId: threadId,
      timeline: [
        TimelineItem(
          id: '$threadId-message',
          kind: TimelineKind.assistant,
          text: text,
        ),
      ],
    );

ProfileDraft _draftFor(ServerSummary server, {required String name}) =>
    ProfileDraft(
      id: server.id,
      name: name,
      host: server.host,
      port: server.port,
      username: server.username,
      authentication: server.authentication,
      password: server.authentication == AuthenticationKind.password
          ? 'password'
          : '',
      privateKeyPem: server.authentication == AuthenticationKind.privateKey
          ? 'private-key'
          : '',
      privateKeyPassphrase: '',
      remoteCodexPort: server.remoteCodexPort,
    );

class _FakeAppServices implements AppServices {
  _FakeAppServices(List<ServerSummary> servers)
    : _servers = List<ServerSummary>.of(servers);

  final List<ServerSummary> _servers;
  final Map<String, List<_FakeConnectedServer>> _connections = {};

  List<_FakeConnectedServer> connectionsFor(String id) =>
      _connections[id] ?? const [];

  _FakeConnectedServer latestConnection(String id) => connectionsFor(id).last;

  @override
  Future<List<ServerSummary>> listServers() async =>
      List<ServerSummary>.unmodifiable(_servers);

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async {
    final connection = _FakeConnectedServer(id);
    _connections.putIfAbsent(id, () => []).add(connection);
    return connection;
  }

  @override
  Future<void> deleteServer(String id) async {
    _servers.removeWhere((server) => server.id == id);
  }

  @override
  Future<ProfileDraft> loadServerDraft(String id) async =>
      _draftFor(_servers.singleWhere((server) => server.id == id), name: id);

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) async {
    final summary = ServerSummary(
      id: draft.id ?? 'new-server',
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authentication: draft.authentication,
      remoteCodexPort: draft.remoteCodexPort,
      hasPinnedHostKey: true,
    );
    final index = _servers.indexWhere((server) => server.id == summary.id);
    if (index < 0) {
      _servers.add(summary);
    } else {
      _servers[index] = summary;
    }
    return summary;
  }
}

class _FakeConnectedServer implements ConnectedServer {
  _FakeConnectedServer(this.serverId) : codex = _FakeCodexPort(serverId);

  final String serverId;
  final _links = StreamController<LinkSnapshot>.broadcast();
  final _FakeCodexPort codex;
  final List<String> createdPersistentShells = [];
  final List<String> deletedPersistentShells = [];
  int disconnectCalls = 0;
  bool _connected = true;
  int _shellSequence = 0;

  @override
  bool get isConnected => _connected;

  @override
  Stream<LinkSnapshot> get linkStates => _links.stream;

  void emitLink(LinkSnapshot snapshot) {
    _links.add(snapshot);
  }

  @override
  Future<ShellHandle> openShell() async =>
      _FakeShellHandle('$serverId/shell-${++_shellSequence}');

  @override
  Future<ShellHandle> createPersistentShell(String id) async {
    createdPersistentShells.add(id);
    return _FakeShellHandle('$serverId/$id');
  }

  @override
  Future<List<String>> listPersistentShells() async =>
      List<String>.unmodifiable(createdPersistentShells);

  @override
  Future<ShellHandle> attachPersistentShell(String id) async =>
      _FakeShellHandle('$serverId/$id');

  @override
  Future<void> deletePersistentShell(String id) async {
    deletedPersistentShells.add(id);
    createdPersistentShells.remove(id);
  }

  @override
  Future<CodexPort> openCodex() async => codex;

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
    _connected = false;
  }
}

class _FakeShellHandle implements ShellHandle {
  _FakeShellHandle(this.owner);

  final String owner;
  bool closed = false;

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  Future<void> close() async => closed = true;

  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  void write(String data) {}
}

class _FakeCodexPort implements CodexPort {
  _FakeCodexPort(this.serverId);

  final String serverId;
  final _snapshots = StreamController<CodexWorkspaceSnapshot>.broadcast();
  CodexWorkspaceSnapshot _current = const CodexWorkspaceSnapshot(
    connected: true,
  );
  bool disposed = false;

  @override
  CodexWorkspaceSnapshot get current => _current;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _snapshots.stream;

  void emit(CodexWorkspaceSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> refreshThreads() async {}

  @override
  Future<void> loadMoreThreads() async {}

  @override
  Future<void> archiveThread(String id) async {}

  @override
  Future<void> createThread({String? cwd}) async {}

  @override
  Future<void> openThread(String id) async {}

  @override
  Future<void> send(String text, {SkillChoice? skill}) async {}

  @override
  Future<void> runCommand(String command) async {}

  @override
  Future<void> selectModel(String model) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> decideApproval(
    ApprovalPrompt prompt, {
    required bool approved,
  }) async {}

  @override
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  ) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
