import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';

void main() {
  test(
    'PocketController ignores a server list completed after dispose',
    () async {
      final services = _ControllableServices();
      final controller = PocketController(services);
      final pending = controller.initialize();

      controller.dispose();
      services.listCompleter.complete([_server]);

      await pending;
      expect(controller.servers, isEmpty);
    },
  );

  test(
    'a connection completed after controller dispose is disconnected',
    () async {
      final services = _ControllableServices(listResult: [_server]);
      final controller = PocketController(services);
      await controller.initialize();
      final pending = controller.openServer(_server, (_) async => true);
      final connection = _ControllableConnection();
      await Future<void>.delayed(Duration.zero);

      controller.dispose();
      services.connectCompleter.complete(connection);

      expect(await pending, isNull);
      expect(connection.disconnected, isTrue);
    },
  );

  test('a shell completed after workspace dispose is closed', () async {
    final connection = _ControllableConnection();
    final services = _ControllableServices(
      listResult: [_server],
      immediateConnection: connection,
    );
    final workspace = ServerWorkspace(server: _server, services: services);
    expect(await workspace.connect((_) async => true), isTrue);
    final pending = workspace.openTerminal();
    final shell = _FakeShellHandle();

    workspace.dispose();
    connection.shellCompleter.complete(shell);

    await pending;
    expect(shell.closed, isTrue);
    expect(workspace.terminals, isEmpty);
    await workspace.shutdown();
  });

  test('a Codex port completed after workspace dispose is closed', () async {
    final connection = _ControllableConnection();
    final services = _ControllableServices(
      listResult: [_server],
      immediateConnection: connection,
    );
    final workspace = ServerWorkspace(server: _server, services: services);
    expect(await workspace.connect((_) async => true), isTrue);
    final pending = workspace.openCodex();
    final port = _FakeCodexPort();

    workspace.dispose();
    connection.codexCompleter.complete(port);

    await pending;
    expect(port.disposed, isTrue);
    expect(workspace.codex, isNull);
    await workspace.shutdown();
  });

  test('thread list navigation survives later Codex snapshots', () async {
    final port = _FakeCodexPort(
      const CodexWorkspaceSnapshot(
        connected: true,
        activeThreadId: 'thread-1',
        timeline: [
          TimelineItem(
            id: 'message-1',
            kind: TimelineKind.assistant,
            text: 'detail',
          ),
        ],
      ),
    );
    final connection = _ControllableConnection(immediateCodex: port);
    final workspace = ServerWorkspace(
      server: _server,
      services: _ControllableServices(
        listResult: [_server],
        immediateConnection: connection,
      ),
    );
    expect(await workspace.connect((_) async => true), isTrue);
    await workspace.openCodex();
    expect(workspace.codexSnapshot.activeThreadId, 'thread-1');

    workspace.showCodexThreadList();
    port.emitBackgroundUpdate();
    await Future<void>.delayed(Duration.zero);

    expect(port.showThreadListCalls, 1);
    expect(workspace.codexSnapshot.activeThreadId, isNull);
    expect(workspace.codexSnapshot.timeline, isEmpty);
    await workspace.shutdown();
    workspace.dispose();
  });

  test('SSH link updates remain active after retryCodex', () async {
    final connection = _ControllableConnection(
      immediateCodex: _FakeCodexPort(),
    );
    final workspace = ServerWorkspace(
      server: _server,
      services: _ControllableServices(
        listResult: [_server],
        immediateConnection: connection,
      ),
    );
    expect(await workspace.connect((_) async => true), isTrue);

    await workspace.retryCodex();
    connection.emitLink(const LinkSnapshot(LinkPhase.disconnected));
    await Future<void>.delayed(Duration.zero);

    expect(workspace.link.phase, LinkPhase.disconnected);
    await workspace.shutdown();
    workspace.dispose();
  });
}

const _server = ServerSummary(
  id: 'server-1',
  name: '服务器',
  host: 'server.test',
  port: 22,
  username: 'coder',
  authentication: AuthenticationKind.password,
  remoteCodexPort: 4500,
  hasPinnedHostKey: true,
);

class _ControllableServices implements AppServices {
  _ControllableServices({this.listResult, this.immediateConnection});

  final List<ServerSummary>? listResult;
  final ConnectedServer? immediateConnection;
  final listCompleter = Completer<List<ServerSummary>>();
  final connectCompleter = Completer<ConnectedServer>();

  @override
  Future<List<ServerSummary>> listServers() =>
      listResult == null ? listCompleter.future : Future.value(listResult);

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) => immediateConnection == null
      ? connectCompleter.future
      : Future.value(immediateConnection);

  @override
  Future<void> deleteServer(String id) async {}

  @override
  Future<ProfileDraft> loadServerDraft(String id) => throw UnimplementedError();

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) =>
      throw UnimplementedError();
}

class _ControllableConnection implements ConnectedServer {
  _ControllableConnection({this.immediateCodex});

  final CodexPort? immediateCodex;
  final _links = StreamController<LinkSnapshot>.broadcast();
  final shellCompleter = Completer<ShellHandle>();
  final codexCompleter = Completer<CodexPort>();
  bool disconnected = false;

  @override
  bool get isConnected => !disconnected;

  @override
  Stream<LinkSnapshot> get linkStates => _links.stream;

  void emitLink(LinkSnapshot snapshot) {
    if (snapshot.phase == LinkPhase.disconnected ||
        snapshot.phase == LinkPhase.failed) {
      disconnected = true;
    }
    _links.add(snapshot);
  }

  @override
  Future<ShellHandle> openShell() => shellCompleter.future;

  @override
  Future<ShellHandle> createPersistentShell(String id) => shellCompleter.future;

  @override
  Future<ShellHandle> attachPersistentShell(String id) => shellCompleter.future;

  @override
  Future<List<String>> listPersistentShells() async => const [];

  @override
  Future<void> deletePersistentShell(String id) async {}

  @override
  Future<CodexPort> openCodex() => immediateCodex == null
      ? codexCompleter.future
      : Future.value(immediateCodex);

  @override
  Future<void> disconnect() async {
    disconnected = true;
    await _links.close();
  }
}

class _FakeShellHandle implements ShellHandle {
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

class _FakeCodexPort implements CodexPort, CodexNavigationPort {
  _FakeCodexPort([
    this._current = const CodexWorkspaceSnapshot(connected: true),
  ]);

  final _snapshots = StreamController<CodexWorkspaceSnapshot>.broadcast();
  CodexWorkspaceSnapshot _current;
  bool disposed = false;
  bool _threadListVisible = false;
  int showThreadListCalls = 0;

  @override
  CodexWorkspaceSnapshot get current => _current;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _snapshots.stream;

  @override
  void showThreadList() {
    showThreadListCalls += 1;
    _threadListVisible = true;
    _emit(_current.copyWith(clearActiveThread: true, timeline: const []));
  }

  void emitBackgroundUpdate() {
    final update = _current.copyWith(
      activeThreadId: 'thread-1',
      timeline: const [
        TimelineItem(
          id: 'background',
          kind: TimelineKind.assistant,
          text: 'background update',
        ),
      ],
    );
    _emit(
      _threadListVisible
          ? update.copyWith(clearActiveThread: true, timeline: const [])
          : update,
    );
  }

  void _emit(CodexWorkspaceSnapshot value) {
    _current = value;
    _snapshots.add(value);
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
  Future<void> openThread(String id) async {
    _threadListVisible = false;
  }

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
    if (disposed) return;
    disposed = true;
    await _snapshots.close();
  }
}
