import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/ui/terminal_pane.dart';
import 'package:xterm/xterm.dart';

import '../../integration_test/support/vps_fixture.dart';

void main() {
  testWidgets('persistent terminal dialog survives its route transition', (
    tester,
  ) async {
    final connection = _ConnectedServer();
    final workspace = ServerWorkspace(
      server: const ServerSummary(
        id: 'server-1',
        name: '测试服务器',
        host: 'example.test',
        port: 22,
        username: 'tester',
        authentication: AuthenticationKind.password,
        remoteCodexPort: 4500,
        hasPinnedHostKey: true,
      ),
      services: _Services(),
    )..connection = connection;
    addTearDown(() async {
      await workspace.shutdown();
      workspace.dispose();
    });

    await workspace.openTerminal();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalPane(workspace: workspace)),
      ),
    );

    await enterTerminalCommand(
      tester,
      find.byType(TerminalView),
      "printf 'INPUT_%s_OK\\n' CHANNEL",
    );
    expect(
      connection.shells.single.writes.join(),
      "printf 'INPUT_%s_OK\\n' CHANNEL\r",
    );

    await tester.tap(find.byTooltip('持久终端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建持久终端'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('persistent-terminal-id')),
      'validation-123',
    );
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(workspace.terminals, hasLength(2));
    expect(workspace.terminals.last.id, 'validation-123');
  });
}

class _Services implements AppServices {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConnectedServer implements ConnectedServer {
  var connected = true;
  final shells = <_ShellHandle>[];

  @override
  bool get isConnected => connected;

  @override
  Stream<LinkSnapshot> get linkStates => const Stream.empty();

  @override
  Future<ShellHandle> openShell() async {
    final shell = _ShellHandle();
    shells.add(shell);
    return shell;
  }

  @override
  Future<ShellHandle> createPersistentShell(String id) async {
    final shell = _ShellHandle();
    shells.add(shell);
    return shell;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ShellHandle implements ShellHandle {
  final writes = <String>[];

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) => writes.add(data);

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
