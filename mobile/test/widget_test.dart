import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_repository.dart';
import 'package:pocket_agent/core/server_secret.dart';
import 'package:pocket_agent/ui/pocket_app.dart';

void main() {
  testWidgets('shows an actionable empty server state', (tester) async {
    await tester.pumpWidget(PocketAgentApp(services: _FakeServices()));
    await tester.pumpAndSettle();

    expect(find.text('还没有服务器'), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
  });

  testWidgets('server form stays usable on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PocketAgentApp(services: _FakeServices()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加服务器').last);
    await tester.pumpAndSettle();

    expect(find.text('连接信息'), findsOneWidget);
    expect(find.text('主机名或 IP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders independent saved server identity', (tester) async {
    await tester.pumpWidget(
      PocketAgentApp(
        services: _FakeServices(
          servers: const [
            ServerSummary(
              id: 'alpha',
              name: '开发机',
              host: 'dev.example.test',
              port: 2222,
              username: 'coder',
              authentication: AuthenticationKind.privateKey,
              remoteCodexPort: 4500,
              hasPinnedHostKey: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开发机'), findsOneWidget);
    expect(find.text('coder@dev.example.test:2222'), findsOneWidget);
    expect(find.text('主机密钥已固定'), findsOneWidget);
  });

  testWidgets('saved server metadata wraps at 320px with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      PocketAgentApp(
        services: _FakeServices(
          servers: const [
            ServerSummary(
              id: 'fixed-password',
              name: '固定主机',
              host: 'fixed.example.test',
              port: 22,
              username: 'coder',
              authentication: AuthenticationKind.password,
              remoteCodexPort: 4500,
              hasPinnedHostKey: true,
            ),
            ServerSummary(
              id: 'first-use-password',
              name: '首次连接主机',
              host: 'first-use.example.test',
              port: 2222,
              username: 'admin',
              authentication: AuthenticationKind.password,
              remoteCodexPort: 4500,
              hasPinnedHostKey: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('SSH · 密码登录 · Codex 4500'), findsNWidgets(2));
    expect(find.text('主机密钥已固定'), findsOneWidget);
    expect(find.text('首次连接需确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved server grid contains metadata at 720px', (tester) async {
    tester.view.physicalSize = const Size(720, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      PocketAgentApp(
        services: _FakeServices(
          servers: const [
            ServerSummary(
              id: 'grid-fixed',
              name: '固定主机',
              host: 'fixed.example.test',
              port: 22,
              username: 'coder',
              authentication: AuthenticationKind.password,
              remoteCodexPort: 4500,
              hasPinnedHostKey: true,
            ),
            ServerSummary(
              id: 'grid-first-use',
              name: '首次连接主机',
              host: 'first-use.example.test',
              port: 2222,
              username: 'admin',
              authentication: AuthenticationKind.password,
              remoteCodexPort: 4500,
              hasPinnedHostKey: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fixed = find.byKey(const ValueKey('server-card-grid-fixed'));
    final firstUse = find.byKey(const ValueKey('server-card-grid-first-use'));
    expect(tester.getCenter(fixed).dy, tester.getCenter(firstUse).dy);
    expect(tester.getCenter(fixed).dx, lessThan(tester.getCenter(firstUse).dx));
    expect(find.text('SSH · 密码登录 · Codex 4500'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('requires explicit first-use host key confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(
      PocketAgentApp(
        services: _FakeServices(
          confirmFirstUse: true,
          servers: const [
            ServerSummary(
              id: 'new-host',
              name: '新服务器',
              host: 'new.example.test',
              port: 22,
              username: 'coder',
              authentication: AuthenticationKind.password,
              remoteCodexPort: 4500,
              hasPinnedHostKey: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新服务器'));
    await tester.pumpAndSettle();

    expect(find.text('确认主机身份'), findsOneWidget);
    expect(find.text('SHA256:test-fingerprint'), findsOneWidget);
    expect(find.text('指纹一致，继续'), findsOneWidget);
  });

  test(
    'editing a server disconnects and invalidates its old workspace',
    () async {
      final services = _TrackingServices();
      final controller = PocketController(services);
      await controller.initialize();
      final oldWorkspace = await controller.openServer(
        controller.servers.single,
        (_) async => true,
      );
      final oldConnection = services.connections.single;

      final saved = await controller.save(
        const ProfileDraft(
          id: 'server-1',
          name: '新名称',
          host: 'new.example.test',
          port: 2200,
          username: 'coder',
          authentication: AuthenticationKind.password,
          password: 'secret',
          privateKeyPem: '',
          privateKeyPassphrase: '',
          remoteCodexPort: 4500,
        ),
      );

      expect(saved?.host, 'new.example.test');
      expect(oldConnection.disconnected, isTrue);
      expect(controller.activeWorkspace, isNull);
      expect(oldWorkspace?.connected, isFalse);
      final reopened = await controller.openServer(
        controller.servers.single,
        (_) async => true,
      );
      expect(reopened, isNot(same(oldWorkspace)));
      expect(reopened?.server.host, 'new.example.test');
      await controller.shutdown();
      controller.dispose();
    },
  );

  for (final change in const [
    ('host', 'other.test', 22),
    ('port', 'old.test', 2222),
  ]) {
    test('changing server ${change.$1} clears the pinned host key', () async {
      final store = _MemoryStore();
      final repository = ServerRepository(
        profileStore: store,
        secretStore: store,
      );
      await repository.save(
        const ServerProfile(
          id: 'server-1',
          name: '服务器',
          host: 'old.test',
          port: 22,
          username: 'coder',
          authentication: SshAuthentication.password,
          hostKeyType: 'ssh-ed25519',
          hostKeyFingerprint: 'SHA256:pinned',
        ),
        ServerSecret(password: 'secret'),
      );
      final services = ProductionAppServices(
        repository: Future.value(repository),
      );

      final saved = await services.saveServer(
        ProfileDraft(
          id: 'server-1',
          name: '服务器',
          host: change.$2,
          port: change.$3,
          username: 'coder',
          authentication: AuthenticationKind.password,
          password: 'secret',
          privateKeyPem: '',
          privateKeyPassphrase: '',
          remoteCodexPort: 4500,
        ),
      );

      expect(saved.hasPinnedHostKey, isFalse);
      expect(
        (await repository.getProfile('server-1'))?.hasPinnedHostKey,
        isFalse,
      );
    });
  }

  testWidgets('shows approval and user-input decisions from Codex', (
    tester,
  ) async {
    final port = _FakeCodexPort(
      CodexWorkspaceSnapshot(
        connected: true,
        activeThreadId: 'thread-1',
        runState: ThreadRunState.waitingApproval,
        accountState: RemoteAccountState.authenticated,
        approval: const ApprovalPrompt(
          id: 'approval-1',
          title: '允许执行命令？',
          details: 'git status',
          raw: 'approval',
        ),
      ),
    );
    await _openCodex(tester, port);

    expect(find.text('允许执行命令？'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
    await tester.pump();
    expect(port.approvalDecision, isTrue);
    expect(find.text('Codex 有 1 个问题需要你回答'), findsOneWidget);

    await tester.tap(find.text('填写回复'));
    await tester.pumpAndSettle();
    expect(find.text('部署区域？'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, 'Shanghai');
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(port.userInputAnswers, {
      'region': ['Shanghai'],
    });
  });

  testWidgets('creates a Codex task without disposing dialog field early', (
    tester,
  ) async {
    final port = _FakeCodexPort(
      const CodexWorkspaceSnapshot(
        connected: true,
        accountState: RemoteAccountState.authenticated,
      ),
    );
    await _openCodex(tester, port);

    await tester.tap(find.byKey(const ValueKey('new-codex-thread')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-thread-cwd')),
      '  /srv/pocket-agent  ',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-new-thread')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(port.createdThreadCwds, ['/srv/pocket-agent']);
  });

  testWidgets('confirms archive, blocks running archive, and loads more', (
    tester,
  ) async {
    final port = _FakeCodexPort(
      const CodexWorkspaceSnapshot(
        connected: true,
        accountState: RemoteAccountState.authenticated,
        nextThreadCursor: 'server-1-page-2',
        threads: [
          ThreadSummary(
            id: 'idle',
            title: '可归档任务',
            preview: '已完成',
            updatedAt: null,
            state: ThreadRunState.idle,
          ),
          ThreadSummary(
            id: 'running',
            title: '运行中任务',
            preview: '进行中',
            updatedAt: null,
            state: ThreadRunState.running,
          ),
        ],
      ),
    );
    await _openCodex(tester, port);

    await tester.tap(find.byKey(const ValueKey('codex-thread-actions-idle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(PopupMenuItem<String>).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('归档任务？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-archive-thread')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(port.archivedIds, ['idle']);

    await tester.tap(
      find.byKey(const ValueKey('codex-thread-actions-running')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final disabledArchive = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('运行中，无法归档'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(disabledArchive.enabled, isFalse);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('load-more-codex-threads')));
    await tester.pump();
    expect(port.loadMoreCalls, 1);
  });

  test('unsupported server requests are rejected fail-closed', () {
    final request = ServerRequest(
      id: 7,
      method: 'item/permissions/requestApproval',
      params: const {'threadId': 'thread-1'},
    );
    ServerRequest? rejected;
    String? rejectionMessage;

    routeMobileServerRequest(
      request,
      activeThreadId: 'thread-1',
      reject: (value, message) {
        rejected = value;
        rejectionMessage = message;
      },
      showUserInput: (_) => fail('must not show user input'),
      showApproval: (_) => fail('must not show approval'),
    );

    expect(rejected, same(request));
    expect(rejectionMessage, contains('does not support'));
  });
}

Future<void> _openCodex(WidgetTester tester, _FakeCodexPort port) async {
  await tester.pumpWidget(
    PocketAgentApp(
      services: _FakeServices(
        codexPort: port,
        servers: const [
          ServerSummary(
            id: 'server-1',
            name: '测试服务器',
            host: 'server.test',
            port: 22,
            username: 'coder',
            authentication: AuthenticationKind.password,
            remoteCodexPort: 4500,
            hasPinnedHostKey: true,
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('server-card-server-1')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Codex'));
  await tester.pump(const Duration(milliseconds: 500));
}

class _FakeServices implements AppServices {
  _FakeServices({
    this.servers = const [],
    this.confirmFirstUse = false,
    this.codexPort,
  });
  final List<ServerSummary> servers;
  final bool confirmFirstUse;
  final CodexPort? codexPort;

  @override
  Future<List<ServerSummary>> listServers() async => servers;

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async {
    if (confirmFirstUse) {
      final accepted = await confirmHostKey(
        const HostKeyPrompt(
          host: 'new.example.test',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:test-fingerprint',
        ),
      );
      if (!accepted) throw StateError('Host key rejected');
    }
    return _FakeConnectedServer(codexPort);
  }

  @override
  Future<void> deleteServer(String id) async {}

  @override
  Future<ProfileDraft> loadServerDraft(String id) => throw UnimplementedError();

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) =>
      throw UnimplementedError();
}

class _FakeConnectedServer implements ConnectedServer {
  _FakeConnectedServer([this.codexPort]);
  final CodexPort? codexPort;
  @override
  bool get isConnected => true;

  @override
  Stream<LinkSnapshot> get linkStates => const Stream.empty();

  @override
  Future<ShellHandle> attachPersistentShell(String id) =>
      throw UnimplementedError();

  @override
  Future<ShellHandle> createPersistentShell(String id) =>
      throw UnimplementedError();

  @override
  Future<void> deletePersistentShell(String id) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<String>> listPersistentShells() async => const [];

  @override
  Future<CodexPort> openCodex() async => codexPort!;

  @override
  Future<ShellHandle> openShell() => throw UnimplementedError();
}

class _FakeCodexPort implements CodexPort {
  _FakeCodexPort(this._current);

  final _snapshots = StreamController<CodexWorkspaceSnapshot>.broadcast();
  CodexWorkspaceSnapshot _current;
  bool? approvalDecision;
  Map<String, List<String>>? userInputAnswers;
  final List<String> archivedIds = [];
  final List<String?> createdThreadCwds = [];
  int loadMoreCalls = 0;

  @override
  CodexWorkspaceSnapshot get current => _current;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _snapshots.stream;

  void _emit(CodexWorkspaceSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> decideApproval(
    ApprovalPrompt prompt, {
    required bool approved,
  }) async {
    approvalDecision = approved;
    _emit(
      _current.copyWith(
        clearApproval: true,
        userInput: const UserInputPrompt(
          questions: [UserInputQuestion(id: 'region', prompt: '部署区域？')],
          raw: 'user-input',
        ),
      ),
    );
  }

  @override
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  ) async {
    userInputAnswers = answers;
    _emit(_current.copyWith(clearUserInput: true));
  }

  @override
  Future<void> archiveThread(String id) async => archivedIds.add(id);

  @override
  Future<void> loadMoreThreads() async => loadMoreCalls += 1;

  @override
  Future<void> refreshThreads() async {}

  @override
  Future<void> createThread({String? cwd}) async => createdThreadCwds.add(cwd);

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
  Future<void> dispose() async => _snapshots.close();
}

class _TrackingServices implements AppServices {
  ServerSummary server = const ServerSummary(
    id: 'server-1',
    name: '旧名称',
    host: 'old.example.test',
    port: 22,
    username: 'coder',
    authentication: AuthenticationKind.password,
    remoteCodexPort: 4500,
    hasPinnedHostKey: true,
  );
  final List<_TrackingConnection> connections = [];

  @override
  Future<List<ServerSummary>> listServers() async => [server];

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async {
    final connection = _TrackingConnection();
    connections.add(connection);
    return connection;
  }

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) async {
    server = ServerSummary(
      id: draft.id!,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authentication: draft.authentication,
      remoteCodexPort: draft.remoteCodexPort,
      hasPinnedHostKey: false,
    );
    return server;
  }

  @override
  Future<void> deleteServer(String id) async {}

  @override
  Future<ProfileDraft> loadServerDraft(String id) => throw UnimplementedError();
}

class _TrackingConnection extends _FakeConnectedServer {
  bool disconnected = false;

  @override
  bool get isConnected => !disconnected;

  @override
  Future<void> disconnect() async => disconnected = true;
}

class _MemoryStore implements ProfileStore, SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
