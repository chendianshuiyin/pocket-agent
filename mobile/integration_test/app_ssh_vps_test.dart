import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_repository.dart';
import 'package:pocket_agent/core/server_secret.dart';
import 'package:pocket_agent/ui/pocket_app.dart';
import 'package:xterm/xterm.dart';

import 'support/vps_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'signed-out real SSH: terminal persistence and Codex initialization',
    (tester) async {
      final ownsTestTextInput = registerFixtureTextInput(tester);
      addTearDown(() {
        if (ownsTestTextInput && tester.testTextInput.isRegistered) {
          tester.testTextInput.unregister();
        }
      });
      final fixture = await loadFixture();
      final repository = await ServerRepository.create();
      final nonce = DateTime.now().millisecondsSinceEpoch.toString();
      final profileId = 'ssh-signed-out-ui-$nonce';
      final persistentId = 'validation-$nonce';
      final profile = ServerProfile(
        id: profileId,
        name: 'Signed-out SSH 验证',
        host: fixtureString(fixture, 'host'),
        port: fixtureInt(fixture, 'port'),
        username: fixtureString(fixture, 'username'),
        authentication: SshAuthentication.password,
        hostKeyType: fixtureString(fixture, 'hostKeyType'),
        hostKeyFingerprint: fixtureString(fixture, 'hostKeyFingerprint'),
        remoteCodexPort: fixtureInt(fixture, 'remoteCodexPort'),
      );
      PocketController? activeController;
      var profileSaved = false;
      var persistentSessionMayExist = false;

      try {
        await repository.save(
          profile,
          ServerSecret(password: fixtureString(fixture, 'password')),
        );
        profileSaved = true;

        activeController = await _launchApp(tester, profileId: profileId);
        await _openServer(tester, profileId);

        await tapWhenHitTestable(tester, find.text('普通终端'));
        await pumpUntil(
          tester,
          () => find.byType(TerminalView).evaluate().isNotEmpty,
        );
        final regularTerminal = find.byType(TerminalView).first;

        final sshMarker = 'SSH_REAL_${nonce}_OK';
        await enterTerminalCommand(
          tester,
          regularTerminal,
          "printf 'SSH_%s_%s_OK\\n' REAL '$nonce'; "
          "printf '\\344'; sleep 0.12; printf '\\270'; sleep 0.12; "
          "printf '\\255'; sleep 0.12; printf '\\346'; sleep 0.12; "
          "printf '\\226'; sleep 0.12; printf '\\207\\n'",
        );
        await pumpUntil(tester, () {
          final text = _terminalText(tester, regularTerminal);
          return text.contains(sshMarker) && text.contains('中文');
        });
        expect(_terminalText(tester, regularTerminal), isNot(contains('�')));

        await tapWhenHitTestable(tester, find.byTooltip('持久终端'));
        await tapWhenHitTestable(tester, find.text('新建持久终端'));
        final persistentIdInput = find.byKey(
          const ValueKey('persistent-terminal-id'),
        );
        await pumpUntil(
          tester,
          () => persistentIdInput.hitTestable().evaluate().isNotEmpty,
        );
        await tester.enterText(persistentIdInput, persistentId);
        persistentSessionMayExist = true;
        await tapWhenHitTestable(
          tester,
          find.widgetWithText(FilledButton, '创建'),
        );

        final persistentTerminal = find.byKey(
          ValueKey('terminal-view-$persistentId'),
        );
        await pumpUntil(tester, () => persistentTerminal.evaluate().isNotEmpty);

        final createdMarker = 'CREATED_PERSIST_${nonce}_OK';
        await enterTerminalCommand(
          tester,
          persistentTerminal,
          "export POCKET_AGENT_UI_SENTINEL='PERSIST_'"
          "\$(printf '%s' '$nonce')'_OK'; "
          "printf 'CREATED_%s\\n' \"\$POCKET_AGENT_UI_SENTINEL\"",
        );
        await pumpUntil(
          tester,
          () =>
              _terminalText(tester, persistentTerminal).contains(createdMarker),
        );

        final firstController = activeController;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await firstController.shutdown();
        firstController.dispose();
        activeController = null;

        activeController = await _launchApp(tester, profileId: profileId);
        await _openServer(tester, profileId);

        await tapWhenHitTestable(tester, find.text('附加已有'));
        await tapWhenHitTestable(tester, find.text(persistentId));
        final reattachedTerminal = find.byKey(
          ValueKey('terminal-view-$persistentId'),
        );
        await pumpUntil(tester, () => reattachedTerminal.evaluate().isNotEmpty);

        final reattachedMarker = 'REATTACH_PERSIST_${nonce}_OK';
        await enterTerminalCommand(
          tester,
          reattachedTerminal,
          "printf 'REATTACH_%s\\n' \"\$POCKET_AGENT_UI_SENTINEL\"",
        );
        await pumpUntil(
          tester,
          () => _terminalText(
            tester,
            reattachedTerminal,
          ).contains(reattachedMarker),
        );

        await tapWhenHitTestable(tester, find.text('Codex'));
        await pumpUntil(
          tester,
          () =>
              activeController!.activeWorkspace!.codexSnapshot.connected &&
              !activeController.activeWorkspace!.codexSnapshot.loading &&
              !activeController.activeWorkspace!.busy &&
              find.textContaining('远端 Codex 尚未登录').evaluate().isNotEmpty,
          timeout: const Duration(minutes: 2),
        );
        await tester.pump();
        expect(activeController.activeWorkspace!.codexSnapshot.error, isNull);
        final newThread = find.byKey(const ValueKey('new-codex-thread'));
        final refresh = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '刷新任务',
        );
        expect(newThread, findsOneWidget);
        expect(refresh, findsOneWidget);
        expect(tester.widget<FilledButton>(newThread).onPressed, isNotNull);
        expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      } finally {
        Object? persistentCleanupError;
        StackTrace? persistentCleanupStack;
        if (persistentSessionMayExist) {
          try {
            await _deleteExactPersistentSession(
              controller: activeController,
              profileId: profileId,
              persistentId: persistentId,
            );
          } catch (error, stackTrace) {
            persistentCleanupError = error;
            persistentCleanupStack = stackTrace;
          }
        }
        final controllerToClose = activeController;
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await controllerToClose?.shutdown();
          controllerToClose?.dispose();
        } finally {
          if (profileSaved) await repository.delete(profileId);
        }
        if (persistentCleanupError != null) {
          Error.throwWithStackTrace(
            persistentCleanupError,
            persistentCleanupStack!,
          );
        }
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<PocketController> _launchApp(
  WidgetTester tester, {
  required String profileId,
}) async {
  final services = ProductionAppServices();
  final controller = PocketController(services);
  await tester.pumpWidget(
    PocketAgentApp(services: services, controller: controller),
  );
  await pumpUntil(
    tester,
    () => find.byKey(ValueKey('server-card-$profileId')).evaluate().isNotEmpty,
  );
  return controller;
}

Future<void> _openServer(WidgetTester tester, String profileId) async {
  await tapWhenHitTestable(
    tester,
    find.byKey(ValueKey('server-card-$profileId')),
  );
  await pumpUntil(tester, () => find.text('SSH 已连接').evaluate().isNotEmpty);
}

String _terminalText(WidgetTester tester, Finder terminal) =>
    tester.widget<TerminalView>(terminal).terminal.buffer.getText();

Future<void> _deleteExactPersistentSession({
  required PocketController? controller,
  required String profileId,
  required String persistentId,
}) async {
  final workspace = controller?.activeWorkspace;
  if (workspace?.connected == true) {
    try {
      await workspace!.deletePersistentShell(persistentId);
      return;
    } catch (_) {
      // Fall through to a fresh connection if the active one is unhealthy.
    }
  }

  ConnectedServer? connection;
  try {
    connection = await ProductionAppServices().connectServer(
      profileId,
      confirmHostKey: (_) async => false,
    );
    await connection.deletePersistentShell(persistentId);
  } finally {
    await connection?.disconnect();
  }
}
