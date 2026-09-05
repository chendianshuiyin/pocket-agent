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
    'live VPS: complete SSH and Codex workflow through the real UI',
    (tester) async {
      final ownsTestTextInput = registerFixtureTextInput(tester);
      addTearDown(() {
        if (ownsTestTextInput && tester.testTextInput.isRegistered) {
          tester.testTextInput.unregister();
        }
      });
      final fixture = await loadFixture();
      final repository = await ServerRepository.create();
      final profileId =
          'ui-validation-${DateTime.now().millisecondsSinceEpoch}';
      final profile = ServerProfile(
        id: profileId,
        name: 'UI 验证服务器',
        host: fixtureString(fixture, 'host'),
        port: fixtureInt(fixture, 'port'),
        username: fixtureString(fixture, 'username'),
        authentication: SshAuthentication.password,
        hostKeyType: fixtureString(fixture, 'hostKeyType'),
        hostKeyFingerprint: fixtureString(fixture, 'hostKeyFingerprint'),
        remoteCodexPort: fixtureInt(fixture, 'remoteCodexPort'),
      );
      PocketController? activeController;

      try {
        await repository.save(
          profile,
          ServerSecret(password: fixtureString(fixture, 'password')),
        );

        final services = ProductionAppServices();
        activeController = PocketController(services);
        await tester.pumpWidget(
          PocketAgentApp(services: services, controller: activeController),
        );
        await pumpUntil(
          tester,
          () => find
              .byKey(ValueKey('server-card-$profileId'))
              .evaluate()
              .isNotEmpty,
        );

        await tapWhenHitTestable(
          tester,
          find.byKey(ValueKey('server-card-$profileId')),
        );
        await pumpUntil(
          tester,
          () => find.text('SSH 已连接').evaluate().isNotEmpty,
        );
        await tapWhenHitTestable(tester, find.text('普通终端'));
        await pumpUntil(
          tester,
          () => find.byType(TerminalView).evaluate().isNotEmpty,
        );

        final terminalFinder = find.byType(TerminalView).first;
        const sshMarker = 'UI_SSH_OK';
        await enterTerminalCommand(
          tester,
          terminalFinder,
          "printf 'UI_%s_OK\\n' SSH",
        );
        await pumpUntil(
          tester,
          () => tester
              .widget<TerminalView>(terminalFinder)
              .terminal
              .buffer
              .getText()
              .contains(sshMarker),
        );

        await tapWhenHitTestable(tester, find.text('Codex'));
        final newThreadButton = find.byKey(const ValueKey('new-codex-thread'));
        await pumpUntil(
          tester,
          () =>
              newThreadButton.hitTestable().evaluate().isNotEmpty &&
              tester.widget<FilledButton>(newThreadButton).onPressed != null,
          timeout: const Duration(minutes: 2),
        );
        await tapWhenHitTestable(tester, newThreadButton);
        final cwdField = find.byKey(const ValueKey('new-thread-cwd'));
        await pumpUntil(
          tester,
          () =>
              cwdField.hitTestable().evaluate().isNotEmpty &&
              tester.widget<TextField>(cwdField).enabled != false,
        );
        await tester.enterText(cwdField, fixtureString(fixture, 'cwd'));
        await tapWhenHitTestable(
          tester,
          find.byKey(const ValueKey('confirm-new-thread')),
        );
        final composer = find.byKey(const ValueKey('codex-composer'));
        await pumpUntil(
          tester,
          () =>
              composer.hitTestable().evaluate().isNotEmpty &&
              tester.widget<TextField>(composer).enabled != false,
        );

        final modelPicker = find.byKey(const ValueKey('codex-model-picker'));
        await pumpUntil(
          tester,
          () =>
              modelPicker.hitTestable().evaluate().isNotEmpty &&
              tester.widget<PopupMenuButton<String>>(modelPicker).enabled,
        );
        await tapWhenHitTestable(tester, modelPicker);
        final preferredModel = find.byKey(
          const ValueKey('codex-model-gpt-5.6-sol'),
        );
        final modelOptions = find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem<String>,
          description: 'Codex model options',
        );
        await pumpUntil(tester, () => modelOptions.evaluate().isNotEmpty);
        if (preferredModel.evaluate().isNotEmpty) {
          await tapWhenHitTestable(tester, preferredModel.last);
        } else {
          await tester.tapAt(const Offset(4, 4));
        }
        await pumpUntil(tester, () => modelOptions.evaluate().isEmpty);

        final codexMarker =
            'UI_CODEX_OK_${DateTime.now().microsecondsSinceEpoch}';
        await tester.enterText(
          composer,
          'Reply exactly $codexMarker. No tools.',
        );
        final sendButton = _enabledIconButton('发送');
        await pumpUntil(
          tester,
          () => sendButton.hitTestable().evaluate().isNotEmpty,
        );
        await tapWhenHitTestable(tester, sendButton);
        await pumpUntil(
          tester,
          () => _completedRunStatus().evaluate().isNotEmpty,
          timeout: const Duration(minutes: 3),
        );
        await pumpUntil(
          tester,
          () => _assistantMarker(codexMarker).evaluate().isNotEmpty,
        );

        await tapWhenHitTestable(tester, find.byTooltip('返回任务列表'));
        final refreshButton = _enabledIconButton('刷新任务');
        await pumpUntil(
          tester,
          () => refreshButton.hitTestable().evaluate().isNotEmpty,
        );
        await tapWhenHitTestable(tester, refreshButton);
        await pumpUntil(
          tester,
          () => find
              .ancestor(
                of: find.textContaining(codexMarker),
                matching: _threadTiles(),
              )
              .evaluate()
              .isNotEmpty,
        );
        final createdTile = find.ancestor(
          of: find.textContaining(codexMarker),
          matching: _threadTiles(),
        );
        final historyKey = tester.widget<ListTile>(createdTile.first).key!;
        await tapWhenHitTestable(tester, find.byKey(historyKey));
        await pumpUntil(
          tester,
          () => _assistantMarker(codexMarker).evaluate().isNotEmpty,
        );

        await tapWhenHitTestable(
          tester,
          find.byKey(const ValueKey('codex-actions')),
        );
        await tester.pumpAndSettle();
        expect(find.text('/review').evaluate().isNotEmpty, isTrue);
        expect(find.text('技能').evaluate().isNotEmpty, isTrue);
        await tapWhenHitTestable(tester, find.text('/status'));
        await pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('codex-composer'))
              .evaluate()
              .isNotEmpty,
        );

        final firstController = activeController;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await firstController.shutdown();
        firstController.dispose();
        activeController = null;

        final rebuiltServices = ProductionAppServices();
        activeController = PocketController(rebuiltServices);
        await tester.pumpWidget(
          PocketAgentApp(
            services: rebuiltServices,
            controller: activeController,
          ),
        );
        await pumpUntil(
          tester,
          () => find
              .byKey(ValueKey('server-card-$profileId'))
              .evaluate()
              .isNotEmpty,
        );
        await tapWhenHitTestable(
          tester,
          find.byKey(ValueKey('server-card-$profileId')),
        );
        await pumpUntil(
          tester,
          () => find.text('SSH 已连接').evaluate().isNotEmpty,
        );
        await tapWhenHitTestable(tester, find.text('Codex'));
        await pumpUntil(
          tester,
          () => find.byKey(historyKey).evaluate().isNotEmpty,
          timeout: const Duration(minutes: 2),
        );
      } finally {
        final controllerToClose = activeController;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await controllerToClose?.shutdown();
        controllerToClose?.dispose();
        await repository.delete(profileId);
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Finder _threadTiles() => find.byWidgetPredicate(
  (widget) =>
      widget is ListTile &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('codex-thread-'),
  description: 'Codex thread tiles',
);

Finder _enabledIconButton(String tooltip) => find.byWidgetPredicate(
  (widget) =>
      widget is IconButton &&
      widget.tooltip == tooltip &&
      widget.onPressed != null,
  description: 'enabled $tooltip button',
);

Finder _completedRunStatus() => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.key == const ValueKey('codex-run-status') &&
      (widget.data == '已完成' || widget.data?.startsWith('已完成 · ') == true),
  description: 'completed Codex run status',
);

Finder _assistantMarker(String marker) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'codex-timeline-assistant-',
        ),
    description: 'assistant timeline cards',
  ),
  matching: find.textContaining(marker),
);
