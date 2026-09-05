import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/ui/codex_pane.dart';
import 'package:pocket_agent/ui/theme/pocket_theme.dart';

void main() {
  testWidgets('a draft from thread A is not sent after switching to thread B', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);

    await tester.enterText(
      find.byKey(const ValueKey('codex-composer')),
      'draft for thread A',
    );
    await tester.tap(find.byKey(const ValueKey('codex-thread-thread-b')));
    await tester.pump();
    expect(fixture.port.current.activeThreadId, 'thread-b');

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(
      fixture.port.sends,
      isEmpty,
      reason:
          'Thread A draft must not be submitted to the newly active thread B.',
    );
    await tester.tap(find.byKey(const ValueKey('codex-thread-thread-a')));
    await tester.pump();
    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('codex-composer')),
    );
    expect(composer.controller!.text, 'draft for thread A');
  });

  testWidgets('a skill selected for thread A is not sent from thread B', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);

    await tester.tap(find.byKey(const ValueKey('codex-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A-only-skill'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex-thread-thread-b')));
    await tester.pump();
    expect(fixture.port.current.activeThreadId, 'thread-b');
    expect(find.text('A-only-skill'), findsNothing);

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(
      fixture.port.sends,
      isEmpty,
      reason:
          'Thread A skill must not be submitted to the newly active thread B.',
    );
    await tester.tap(find.byKey(const ValueKey('codex-thread-thread-a')));
    await tester.pump();
    expect(find.text('A-only-skill'), findsOneWidget);
  });

  testWidgets('an action sheet opened on thread A cannot command thread B', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);

    await tester.tap(find.byKey(const ValueKey('codex-actions')));
    await tester.pumpAndSettle();
    expect(find.text('/review'), findsOneWidget);

    fixture.port.switchThread('thread-b');
    await tester.pump();
    expect(fixture.port.current.activeThreadId, 'thread-b');
    fixture.port.switchThread('thread-a');
    await tester.pump();
    expect(fixture.port.current.activeThreadId, 'thread-a');
    await tester.tap(find.text('/review'));
    await tester.pumpAndSettle();

    expect(
      fixture.port.commands,
      isEmpty,
      reason: 'A sheet opened for thread A must become stale after a switch.',
    );
  });

  testWidgets('an action from a replaced Codex port is discarded', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);
    final stalePort = fixture.port;

    await tester.tap(find.byKey(const ValueKey('codex-actions')));
    await tester.pumpAndSettle();
    final replacementPort = _FakeCodexPort();
    fixture.connection.port = replacementPort;
    fixture.workspace.codex = replacementPort;
    fixture.workspace.codexSnapshot = replacementPort.current;
    fixture.workspace.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('/review'));
    await tester.pumpAndSettle();

    expect(stalePort.commands, isEmpty);
    expect(replacementPort.commands, isEmpty);
  });

  for (final state in const [
    ThreadRunState.running,
    ThreadRunState.waitingApproval,
  ]) {
    testWidgets(
      'an open action sheet becomes stale when state is ${state.name}',
      (tester) async {
        final fixture = await _pumpCodexPane(tester);

        await tester.tap(find.byKey(const ValueKey('codex-actions')));
        await tester.pumpAndSettle();
        fixture.port.updateRunState(state);
        await tester.pump();
        await tester.tap(find.text('/review'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(fixture.port.commands, isEmpty);
      },
    );
  }

  testWidgets('same thread id in another workspace does not reuse a draft', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);
    await tester.enterText(
      find.byKey(const ValueKey('codex-composer')),
      'server one draft',
    );
    await tester.tap(find.byKey(const ValueKey('codex-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A-only-skill'));
    await tester.pumpAndSettle();
    final otherPort = _FakeCodexPort();
    final otherWorkspace = await _openWorkspace(otherPort);
    addTearDown(() async {
      await otherWorkspace.shutdown();
      otherWorkspace.dispose();
    });

    fixture.activeWorkspace.value = otherWorkspace;
    await tester.pump();

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('codex-composer')),
    );
    expect(composer.controller!.text, isEmpty);
    expect(find.text('A-only-skill'), findsNothing);
  });

  testWidgets('closing a sheet after the pane is disposed does not setState', (
    tester,
  ) async {
    final fixture = await _pumpCodexPane(tester);

    await tester.tap(find.byKey(const ValueKey('codex-actions')));
    await tester.pumpAndSettle();
    fixture.paneVisible.value = false;
    await tester.pump();
    expect(find.text('A-only-skill'), findsOneWidget);
    await tester.tap(find.text('A-only-skill'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(fixture.port.sends, isEmpty);
    expect(fixture.port.commands, isEmpty);
  });

  for (final state in const [
    ThreadRunState.running,
    ThreadRunState.waitingApproval,
  ]) {
    testWidgets('interrupt remains actionable while ${state.name}', (
      tester,
    ) async {
      final fixture = await _pumpCodexPane(tester, runState: state);

      final composer = tester.widget<TextField>(
        find.byKey(const ValueKey('codex-composer')),
      );
      expect(composer.enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('codex-interrupt')));
      await tester.pump();

      expect(fixture.port.interruptCalls, 1);
    });
  }
}

Future<_Fixture> _pumpCodexPane(
  WidgetTester tester, {
  ThreadRunState runState = ThreadRunState.idle,
}) async {
  final port = _FakeCodexPort(runState);
  final services = _FakeAppServices(port);
  final workspace = await _openWorkspace(port, services: services);
  final activeWorkspace = ValueNotifier(workspace);
  final paneVisible = ValueNotifier(true);
  addTearDown(() async {
    activeWorkspace.dispose();
    paneVisible.dispose();
    await workspace.shutdown();
    workspace.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: PocketTheme.light(),
      home: ValueListenableBuilder<bool>(
        valueListenable: paneVisible,
        builder: (context, visible, _) => Scaffold(
          body: visible
              ? ValueListenableBuilder<ServerWorkspace>(
                  valueListenable: activeWorkspace,
                  builder: (context, active, _) => ListenableBuilder(
                    listenable: active,
                    builder: (context, _) => CodexPane(workspace: active),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(port.current.activeThreadId, 'thread-a');
  expect(find.byKey(const ValueKey('codex-composer')), findsOneWidget);
  return _Fixture(
    workspace,
    services.connection,
    port,
    activeWorkspace,
    paneVisible,
  );
}

Future<ServerWorkspace> _openWorkspace(
  _FakeCodexPort port, {
  _FakeAppServices? services,
}) async {
  final workspace = ServerWorkspace(
    server: _server,
    services: services ?? _FakeAppServices(port),
  );
  expect(await workspace.connect((_) async => true), isTrue);
  await workspace.openCodex();
  return workspace;
}

const _server = ServerSummary(
  id: 'server-1',
  name: 'Test server',
  host: 'server.test',
  port: 22,
  username: 'coder',
  authentication: AuthenticationKind.password,
  remoteCodexPort: 4500,
  hasPinnedHostKey: true,
);

const _threads = [
  ThreadSummary(
    id: 'thread-a',
    title: 'Thread A',
    preview: 'First thread',
    updatedAt: null,
    state: ThreadRunState.idle,
  ),
  ThreadSummary(
    id: 'thread-b',
    title: 'Thread B',
    preview: 'Second thread',
    updatedAt: null,
    state: ThreadRunState.idle,
  ),
];

const _skill = SkillChoice(name: 'A-only-skill', path: '/skills/a/SKILL.md');

CodexWorkspaceSnapshot _snapshot(
  String threadId, {
  ThreadRunState runState = ThreadRunState.idle,
}) => CodexWorkspaceSnapshot(
  connected: true,
  activeThreadId: threadId,
  threads: _threads,
  skills: const [_skill],
  runState: runState,
  accountState: RemoteAccountState.authenticated,
);

class _Fixture {
  const _Fixture(
    this.workspace,
    this.connection,
    this.port,
    this.activeWorkspace,
    this.paneVisible,
  );

  final ServerWorkspace workspace;
  final _FakeConnectedServer connection;
  final _FakeCodexPort port;
  final ValueNotifier<ServerWorkspace> activeWorkspace;
  final ValueNotifier<bool> paneVisible;
}

class _SendRecord {
  const _SendRecord(this.threadId, this.text, this.skill);

  final String? threadId;
  final String text;
  final SkillChoice? skill;

  @override
  String toString() =>
      '_SendRecord(threadId: $threadId, text: $text, skill: ${skill?.name})';
}

class _CommandRecord {
  const _CommandRecord(this.threadId, this.command);

  final String? threadId;
  final String command;

  @override
  String toString() => '_CommandRecord(threadId: $threadId, command: $command)';
}

class _FakeAppServices implements AppServices {
  _FakeAppServices(_FakeCodexPort port)
    : connection = _FakeConnectedServer(port);

  final _FakeConnectedServer connection;

  @override
  Future<List<ServerSummary>> listServers() async => const [_server];

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async => connection;

  @override
  Future<void> deleteServer(String id) => throw UnimplementedError();

  @override
  Future<ProfileDraft> loadServerDraft(String id) => throw UnimplementedError();

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) =>
      throw UnimplementedError();
}

class _FakeConnectedServer implements ConnectedServer {
  _FakeConnectedServer(this.port);

  _FakeCodexPort port;

  @override
  bool get isConnected => true;

  @override
  Stream<LinkSnapshot> get linkStates => const Stream.empty();

  @override
  Future<ShellHandle> openShell() => throw UnimplementedError();

  @override
  Future<ShellHandle> createPersistentShell(String id) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listPersistentShells() => throw UnimplementedError();

  @override
  Future<ShellHandle> attachPersistentShell(String id) =>
      throw UnimplementedError();

  @override
  Future<void> deletePersistentShell(String id) => throw UnimplementedError();

  @override
  Future<CodexPort> openCodex() async => port;

  @override
  Future<void> disconnect() async {}
}

class _FakeCodexPort implements CodexPort {
  _FakeCodexPort([ThreadRunState runState = ThreadRunState.idle])
    : _current = _snapshot('thread-a', runState: runState);

  final _snapshots = StreamController<CodexWorkspaceSnapshot>.broadcast();
  CodexWorkspaceSnapshot _current;
  final List<_SendRecord> sends = [];
  final List<_CommandRecord> commands = [];
  int interruptCalls = 0;
  bool disposed = false;

  @override
  CodexWorkspaceSnapshot get current => _current;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _snapshots.stream;

  void switchThread(String id) {
    _current = _snapshot(id, runState: _current.runState);
    _snapshots.add(_current);
  }

  void updateRunState(ThreadRunState state) {
    _current = _current.copyWith(runState: state);
    _snapshots.add(_current);
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
  Future<void> openThread(String id) async => switchThread(id);

  @override
  Future<void> send(String text, {SkillChoice? skill}) async {
    sends.add(_SendRecord(_current.activeThreadId, text, skill));
  }

  @override
  Future<void> runCommand(String command) async {
    commands.add(_CommandRecord(_current.activeThreadId, command));
  }

  @override
  Future<void> selectModel(String model) async {}

  @override
  Future<void> interrupt() async => interruptCalls += 1;

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
