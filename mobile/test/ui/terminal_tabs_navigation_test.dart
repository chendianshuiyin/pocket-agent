import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/ui/terminal_pane.dart';
import 'package:pocket_agent/ui/theme/pocket_theme.dart';

void main() {
  testWidgets('terminal tabs keep a 48dp target and expose long titles', (
    tester,
  ) async {
    final workspace = await _workspaceWithTabs([
      null,
      'preview-build-with-a-very-long-session-name',
      'preview-logs',
    ]);
    addTearDown(() => _dispose(workspace));

    await tester.pumpWidget(_testApp(workspace));
    await tester.pump();

    final chip = find.byKey(
      const ValueKey(
        'terminal-tab-preview-build-with-a-very-long-session-name',
      ),
    );
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    final title = tester.widget<Text>(
      find.descendant(
        of: chip,
        matching: find.text('preview-build-with-a-very-long-session-name'),
      ),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(of: chip, matching: find.byType(Tooltip)),
          )
          .message,
      'preview-build-with-a-very-long-session-name',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected last tab is fully visible at 320px and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final workspace = await _workspaceWithTabs([
      null,
      'build-one',
      'build-two',
      'build-three',
      'active-last',
    ], selected: 4);
    addTearDown(() => _dispose(workspace));

    await tester.pumpWidget(_testApp(workspace));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    _expectFullyVisible(tester, 'active-last');
    expect(
      tester
          .getSize(find.byKey(const ValueKey('terminal-tab-active-last')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('active middle tab remains visible when viewport narrows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = await _workspaceWithTabs([
      null,
      'build-one',
      'active-middle',
      'build-three',
      'build-four',
    ], selected: 2);
    addTearDown(() => _dispose(workspace));

    await tester.pumpWidget(_testApp(workspace));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    _expectFullyVisible(tester, 'active-middle');

    tester.view.physicalSize = const Size(320, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 220));

    expect(workspace.selectedTerminal, 2);
    _expectFullyVisible(tester, 'active-middle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding and closing tabs keeps the active tab visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = await _workspaceWithTabs([
      null,
      'build-one',
      'build-two',
    ]);
    addTearDown(() => _dispose(workspace));

    await tester.pumpWidget(_testApp(workspace));
    await tester.pump();
    await tester.tap(find.byTooltip('新建终端'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 220));

    expect(workspace.selectedTerminal, 3);
    final addedId = workspace.terminals.last.id;
    _expectFullyVisible(tester, addedId);

    final activeChip = tester.widget<InputChip>(
      find.byKey(ValueKey('terminal-tab-$addedId')),
    );
    activeChip.onDeleted!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 220));

    expect(workspace.terminals, hasLength(3));
    expect(workspace.selectedTerminal, 2);
    _expectFullyVisible(tester, 'build-two');
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp(ServerWorkspace workspace) => MaterialApp(
  theme: PocketTheme.light(),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: workspace,
      builder: (_, _) => TerminalPane(workspace: workspace),
    ),
  ),
);

void _expectFullyVisible(WidgetTester tester, String id) {
  final viewport = tester.getRect(
    find.byKey(const ValueKey('terminal-tabs-scroll')),
  );
  final tab = tester.getRect(find.byKey(ValueKey('terminal-tab-slot-$id')));
  expect(tab.left, greaterThanOrEqualTo(viewport.left - 0.5));
  expect(tab.right, lessThanOrEqualTo(viewport.right + 0.5));
}

Future<ServerWorkspace> _workspaceWithTabs(
  List<String?> persistentIds, {
  int selected = 0,
}) async {
  final connection = _ConnectedServer();
  final workspace = ServerWorkspace(
    server: const ServerSummary(
      id: 'tabs-test',
      name: '终端测试',
      host: 'example.test',
      port: 22,
      username: 'tester',
      authentication: AuthenticationKind.privateKey,
      remoteCodexPort: 4500,
      hasPinnedHostKey: true,
    ),
    services: _Services(connection),
  )..connection = connection;
  for (final id in persistentIds) {
    await workspace.openTerminal(persistent: id != null, id: id);
  }
  workspace.selectTerminal(selected);
  return workspace;
}

Future<void> _dispose(ServerWorkspace workspace) async {
  await workspace.shutdown();
  workspace.dispose();
}

class _Services implements AppServices {
  const _Services(this.connection);
  final ConnectedServer connection;

  @override
  Future<List<ServerSummary>> listServers() async => const [];
  @override
  Future<ProfileDraft> loadServerDraft(String id) =>
      Future.error(StateError('Not used by terminal tab tests'));
  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) =>
      Future.error(StateError('Not used by terminal tab tests'));
  @override
  Future<void> deleteServer(String id) async {}
  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async => connection;
}

class _ConnectedServer implements ConnectedServer {
  bool connected = true;
  var shellCount = 0;

  @override
  bool get isConnected => connected;
  @override
  Stream<LinkSnapshot> get linkStates => const Stream.empty();
  @override
  Future<ShellHandle> openShell() async => _ShellHandle(++shellCount);
  @override
  Future<ShellHandle> createPersistentShell(String id) async =>
      _ShellHandle(++shellCount);
  @override
  Future<List<String>> listPersistentShells() async => const [];
  @override
  Future<ShellHandle> attachPersistentShell(String id) async =>
      _ShellHandle(++shellCount);
  @override
  Future<void> deletePersistentShell(String id) async {}
  @override
  Future<CodexPort> openCodex() =>
      Future.error(StateError('Not used by terminal tab tests'));
  @override
  Future<void> disconnect() async => connected = false;
}

class _ShellHandle implements ShellHandle {
  const _ShellHandle(this.id);
  final int id;

  @override
  Stream<Uint8List> get output => const Stream.empty();
  @override
  void write(String data) {}
  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}
  @override
  Future<void> close() async {}
}
