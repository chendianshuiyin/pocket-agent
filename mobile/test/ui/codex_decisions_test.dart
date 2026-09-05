import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/ui/codex_pane.dart';
import 'package:pocket_agent/ui/server_workspace_screen.dart';
import 'package:pocket_agent/ui/theme/pocket_theme.dart';

void main() {
  testWidgets('long approval details are complete, scrollable, and read-only', (
    tester,
  ) async {
    final details = [
      for (var index = 1; index <= 24; index += 1)
        'command line $index --with-sensitive-context',
      'END_MARKER',
    ].join('\n');
    final prompt = ApprovalPrompt(
      id: 'approval-1',
      title: '允许执行命令？',
      details: details,
      raw: 'opaque-request',
    );
    final port = _DecisionPort(
      _snapshot(approval: prompt, runState: ThreadRunState.waitingApproval),
    );
    await _pumpPane(
      tester,
      port,
      size: const Size(320, 600),
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 180),
      useWorkspaceScreen: true,
    );

    final summary = tester.widget<Text>(find.text(details));
    expect(summary.maxLines, 4);
    expect(summary.overflow, TextOverflow.ellipsis);
    final viewDetails = find.byKey(const ValueKey('view-approval-details'));
    await tester.ensureVisible(viewDetails);
    await tester.pump();
    expect(viewDetails.hitTestable(), findsOneWidget);
    await tester.tap(viewDetails);
    await tester.pumpAndSettle();

    final fullDetails = tester.widget<SelectableText>(
      find.byKey(const ValueKey('approval-details-full')),
    );
    expect(fullDetails.data, details);
    expect(fullDetails.data, endsWith('END_MARKER'));
    final detailsScroll = find.byKey(const ValueKey('approval-details-scroll'));
    final scrollable = find.descendant(
      of: detailsScroll,
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(scrollable.first);
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pump();
    expect(scrollState.position.pixels, scrollState.position.maxScrollExtent);
    expect(
      find.byKey(const ValueKey('close-approval-details')).hitTestable(),
      findsOneWidget,
    );
    expect(port.approvalDecisions, isEmpty);

    await tester.tap(find.byKey(const ValueKey('close-approval-details')));
    await tester.pumpAndSettle();
    expect(port.approvalDecisions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty user input shows required errors in a compact keyboard view',
    (tester) async {
      final prompt = UserInputPrompt(
        raw: 'opaque-request',
        questions: const [
          UserInputQuestion(
            id: 'region',
            prompt: '部署区域？',
            options: ['华东一区（主节点与对象存储位于同一可用区）', '华南二区（跨区域灾备）'],
          ),
          UserInputQuestion(id: 'notes', prompt: '发布说明？'),
        ],
      );
      final port = _DecisionPort(
        _snapshot(userInput: prompt, runState: ThreadRunState.waitingApproval),
      );
      await _pumpPane(
        tester,
        port,
        size: const Size(320, 640),
        textScale: 2,
        viewInsets: const EdgeInsets.only(bottom: 180),
      );

      await tester.tap(find.text('填写回复'));
      await tester.pumpAndSettle();
      final regionDecoration = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(const ValueKey('user-input-region')),
          matching: find.byType(InputDecorator),
        ),
      );
      expect(regionDecoration.decoration.helperMaxLines, 3);
      expect(
        find.byKey(const ValueKey('submit-user-input')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('submit-user-input')));
      await tester.pump();

      expect(find.text('此项为必填'), findsNWidgets(2));
      expect(port.userInputAnswers, isNull);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const ValueKey('user-input-region')),
        '华东一区',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('user-input-notes')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('user-input-notes')),
        '逐步发布',
      );
      expect(
        find.byKey(const ValueKey('submit-user-input')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('submit-user-input')));
      await tester.pumpAndSettle();

      expect(port.userInputAnswers, {
        'region': ['华东一区'],
        'notes': ['逐步发布'],
      });
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPane(
  WidgetTester tester,
  _DecisionPort port, {
  required Size size,
  required double textScale,
  EdgeInsets viewInsets = EdgeInsets.zero,
  bool useWorkspaceScreen = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final workspace =
      ServerWorkspace(server: _server, services: const _UnusedServices())
        ..codex = port
        ..codexSnapshot = port.current
        ..selectedFeature = 1;
  addTearDown(() async {
    await workspace.shutdown();
    workspace.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: PocketTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: viewInsets,
        ),
        child: child!,
      ),
      home: useWorkspaceScreen
          ? ServerWorkspaceScreen(
              workspace: workspace,
              onBack: () {},
              confirmHostKey: (_) async => true,
            )
          : Scaffold(body: CodexPane(workspace: workspace)),
    ),
  );
  await tester.pump();
  expect(find.byType(CodexPane), findsOneWidget);
  expect(tester.takeException(), isNull);
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

CodexWorkspaceSnapshot _snapshot({
  ApprovalPrompt? approval,
  UserInputPrompt? userInput,
  required ThreadRunState runState,
}) => CodexWorkspaceSnapshot(
  connected: true,
  activeThreadId: 'thread-1',
  runState: runState,
  approval: approval,
  userInput: userInput,
  accountState: RemoteAccountState.authenticated,
  timeline: const [
    TimelineItem(
      id: 'message-1',
      kind: TimelineKind.assistant,
      text: 'Waiting for a decision.',
    ),
  ],
);

class _DecisionPort implements CodexPort {
  _DecisionPort(this._current);

  final CodexWorkspaceSnapshot _current;
  final List<bool> approvalDecisions = [];
  Map<String, List<String>>? userInputAnswers;

  @override
  CodexWorkspaceSnapshot get current => _current;

  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => const Stream.empty();

  @override
  Future<void> decideApproval(
    ApprovalPrompt prompt, {
    required bool approved,
  }) async {
    approvalDecisions.add(approved);
  }

  @override
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  ) async {
    userInputAnswers = answers;
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
  Future<void> dispose() async {}
}

class _UnusedServices implements AppServices {
  const _UnusedServices();

  @override
  Future<List<ServerSummary>> listServers() => throw UnimplementedError();

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteServer(String id) => throw UnimplementedError();

  @override
  Future<ProfileDraft> loadServerDraft(String id) => throw UnimplementedError();

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) =>
      throw UnimplementedError();
}
