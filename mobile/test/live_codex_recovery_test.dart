import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

import 'live_vps_test.dart'
    show eventually, fixtureToken, loadFixture, makeConnection;
import 'support/live_command_lifecycle_guard.dart';
import 'support/live_turn_assertions.dart';

const _commandMarker = '__POCKET_RECOVERY_COMMAND__';
const _completionMarker = '__POCKET_RECOVERY_DONE__';
const _recoveryCommand = "sleep 8 && printf '$_commandMarker\\n'";
const _interruptCommand =
    "sleep 30 && printf '__POCKET_INTERRUPT_UNEXPECTED__\\n'";

void main() {
  test(
    'live VPS: an in-flight turn survives RPC, tunnel, and SSH replacement',
    () async {
      final fixture = await loadFixture();
      final cwd = fixture['cwd'] as String;
      SshConnection? ssh;
      CodexTunnel? tunnel;
      CodexClient? rpc;
      StreamSubscription<RpcNotification>? notificationSubscription;
      StreamSubscription<TurnSnapshot>? turnSubscription;
      String? threadId;
      var archived = false;

      try {
        ssh = makeConnection(fixture);
        await ssh
            .connect(onFirstUseHostKey: (_) async => false)
            .timeout(const Duration(seconds: 30));
        tunnel = await RemoteRuntimeManager(ssh)
            .openExistingTunnel()
            .timeout(const Duration(seconds: 30));
        rpc = await CodexClient.connect(
          tunnel.uri,
          headers: tunnel.clientHeaders,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        ).timeout(const Duration(seconds: 30));
        final account = await rpc.readAccount();
        expect(
          account.isAuthenticated,
          isTrue,
          reason: 'The remote Codex runtime must be authenticated before this live test',
        );
        final model = await _preferredModel(rpc);
        final thread = await rpc.startThread(
          cwd: cwd,
          model: model,
          approvalPolicy: CodexApprovalPolicy.never,
          sandbox: CodexSandboxMode.workspaceWrite,
        );
        threadId = thread.id;

        final lifecycle = LiveCommandLifecycleGuard(
          threadId: thread.id,
          expectedCommand: _recoveryCommand,
        );
        notificationSubscription = rpc.notifications.listen(lifecycle.handle);
        final startedTurn = await rpc.sendMessage(
          thread.id,
          _recoveryPrompt(cwd),
          model: model,
          effort: 'low',
        );
        await eventually(
          () => lifecycle.hasRelevantLifecycle(startedTurn.id),
          timeout: const Duration(seconds: 45),
        );
        expect(
          lifecycle.validateInFlight(startedTurn.id),
          isNull,
          reason: 'The expected command must be running when transport shutdown begins',
        );
        // ignore: avoid_print
        print('Recovery test: command started=true');

        await notificationSubscription.cancel();
        notificationSubscription = null;
        await rpc.dispose().timeout(const Duration(seconds: 10));
        rpc = null;
        await tunnel.close().timeout(const Duration(seconds: 10));
        tunnel = null;
        await ssh.disconnect().timeout(const Duration(seconds: 10));
        ssh = null;
        // ignore: avoid_print
        print('Recovery test: first connection closed=true');

        ssh = makeConnection(fixture);
        await ssh
            .connect(onFirstUseHostKey: (_) async => false)
            .timeout(const Duration(seconds: 30));
        tunnel = await RemoteRuntimeManager(ssh)
            .openExistingTunnel()
            .timeout(const Duration(seconds: 30));
        rpc = await CodexClient.connect(
          tunnel.uri,
          headers: tunnel.clientHeaders,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        ).timeout(const Duration(seconds: 30));

        var finished = false;
        String? completedStatus;
        turnSubscription = rpc.turnSnapshots.listen((snapshot) {
          if (snapshot.threadId == thread.id &&
              snapshot.turn.id == startedTurn.id &&
              snapshot.completed) {
            finished = true;
            completedStatus = snapshot.turn.status;
          }
        });
        final restored = await rpc.openThread(thread.id);
        for (final turn in restored.turns) {
          if (turn.id == startedTurn.id && turn.status != 'inProgress') {
            finished = true;
            completedStatus = turn.status;
          }
        }
        await eventually(() => finished, timeout: const Duration(minutes: 2));

        final history = await rpc.readThread(thread.id, includeTurns: true);
        final matchingTurns = history.turns
            .where((turn) => turn.id == startedTurn.id)
            .toList(growable: false);
        expect(
          matchingTurns,
          hasLength(1),
          reason: 'Reconnect must continue the original turn rather than start another one',
        );
        expect(matchingTurns.single.status, 'completed');
        expect(
          successfulCommandOutputContains(matchingTurns.single, _commandMarker),
          isTrue,
        );
        expect(
          agentMessageTextContains(matchingTurns.single, _completionMarker),
          isTrue,
        );
        // ignore: avoid_print
        print(
          'Recovery test: original turn completed=${completedStatus == 'completed'}',
        );

        await rpc.archiveThread(thread.id).timeout(const Duration(seconds: 20));
        archived = true;
      } finally {
        await notificationSubscription?.cancel();
        await turnSubscription?.cancel();
        if (!archived && rpc != null && threadId != null) {
          await _bestEffort(
            rpc.archiveThread(threadId).timeout(const Duration(seconds: 10)),
          );
        }
        await _bestEffort(rpc?.dispose().timeout(const Duration(seconds: 10)));
        await _bestEffort(tunnel?.close().timeout(const Duration(seconds: 10)));
        await _bestEffort(
          ssh?.disconnect().timeout(const Duration(seconds: 10)),
        );
      }
    },
    skip: fixtureToken.isEmpty,
    tags: 'live-vps',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'live VPS: an active command turn can be interrupted',
    () async {
      final fixture = await loadFixture();
      final cwd = fixture['cwd'] as String;
      SshConnection? ssh;
      CodexTunnel? tunnel;
      CodexClient? rpc;
      StreamSubscription<RpcNotification>? notificationSubscription;
      StreamSubscription<TurnSnapshot>? turnSubscription;
      String? threadId;
      var archived = false;

      try {
        ssh = makeConnection(fixture);
        await ssh
            .connect(onFirstUseHostKey: (_) async => false)
            .timeout(const Duration(seconds: 30));
        tunnel = await RemoteRuntimeManager(ssh)
            .openExistingTunnel()
            .timeout(const Duration(seconds: 30));
        rpc = await CodexClient.connect(
          tunnel.uri,
          headers: tunnel.clientHeaders,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        ).timeout(const Duration(seconds: 30));
        final model = await _preferredModel(rpc);
        final thread = await rpc.startThread(
          cwd: cwd,
          model: model,
          approvalPolicy: CodexApprovalPolicy.never,
          sandbox: CodexSandboxMode.workspaceWrite,
        );
        threadId = thread.id;

        final lifecycle = LiveCommandLifecycleGuard(
          threadId: thread.id,
          expectedCommand: _interruptCommand,
        );
        String? terminalStatus;
        notificationSubscription = rpc.notifications.listen(lifecycle.handle);
        final startedTurn = await rpc.sendMessage(
          thread.id,
          _interruptPrompt(cwd),
          model: model,
          effort: 'low',
        );
        turnSubscription = rpc.turnSnapshots.listen((snapshot) {
          if (snapshot.threadId == thread.id &&
              snapshot.turn.id == startedTurn.id &&
              snapshot.completed) {
            terminalStatus = snapshot.turn.status;
          }
        });
        await eventually(
          () => lifecycle.hasRelevantLifecycle(startedTurn.id),
          timeout: const Duration(seconds: 45),
        );
        expect(
          lifecycle.validateInFlight(startedTurn.id),
          isNull,
          reason: 'The expected command must be running before interrupt',
        );
        await rpc
            .interruptTurn(thread.id, startedTurn.id)
            .timeout(const Duration(seconds: 20));
        await eventually(
          () => terminalStatus != null,
          timeout: const Duration(seconds: 30),
        );

        final history = await rpc.readThread(thread.id, includeTurns: true);
        final matchingTurns = history.turns
            .where((turn) => turn.id == startedTurn.id)
            .toList(growable: false);
        expect(matchingTurns, hasLength(1));
        expect(terminalStatus, 'interrupted');
        expect(matchingTurns.single.status, 'interrupted');
        // ignore: avoid_print
        print('Interrupt test: command started=true, interrupted=true');

        await rpc.archiveThread(thread.id).timeout(const Duration(seconds: 20));
        archived = true;
      } finally {
        await notificationSubscription?.cancel();
        await turnSubscription?.cancel();
        if (!archived && rpc != null && threadId != null) {
          await _bestEffort(
            rpc.archiveThread(threadId).timeout(const Duration(seconds: 10)),
          );
        }
        await _bestEffort(rpc?.dispose().timeout(const Duration(seconds: 10)));
        await _bestEffort(tunnel?.close().timeout(const Duration(seconds: 10)));
        await _bestEffort(
          ssh?.disconnect().timeout(const Duration(seconds: 10)),
        );
      }
    },
    skip: fixtureToken.isEmpty,
    tags: 'live-vps',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<String> _preferredModel(CodexClient rpc) async {
  final models = await rpc.listModels();
  expect(models.data, isNotEmpty);
  for (final model in models.data) {
    if (model.model == 'gpt-5.6-sol') return model.model;
  }
  return models.data.first.model;
}

String _recoveryPrompt(String cwd) =>
    '''
Work only inside this working directory: $cwd
Do not read files, environment variables, credentials, or authentication data.
Do not access the network or write any file.
Use the shell tool once to run exactly:
$_recoveryCommand
After it finishes, reply exactly $_completionMarker.
''';

String _interruptPrompt(String cwd) =>
    '''
Work only inside this working directory: $cwd
Do not read files, environment variables, credentials, or authentication data.
Do not access the network or write any file.
Use the shell tool once to run exactly:
$_interruptCommand
Wait for the command before replying.
''';

Future<void> _bestEffort(Future<void>? operation) async {
  if (operation == null) return;
  try {
    await operation;
  } catch (_) {
    // Cleanup is bounded and must not hide the primary test failure.
  }
}
