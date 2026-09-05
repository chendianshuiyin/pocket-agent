import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

import 'live_vps_test.dart'
    show eventually, fixtureToken, loadFixture, makeConnection;
import 'codex/mock_app_server.dart';
import 'support/live_approval_guard.dart';

void main() {
  group('live approval allowlist', () {
    const scope = (threadId: 'thread-1', turnId: 'turn-1', cwd: '/srv/project');

    test('accepts only the exact harmless command and scope', () {
      for (final command in liveApprovalCommands) {
        expect(
          validateLiveCommandApproval(
            _request(command: command),
            threadId: scope.threadId,
            turnId: scope.turnId,
            cwd: scope.cwd,
          ),
          isNull,
        );
      }
    });

    test('rejects marker-containing commands and extra capabilities', () {
      for (final request in [
        _request(command: '$liveApprovalCommand; uname -a'),
        _request(command: "/bin/sh -lc \"$liveApprovalCommand\""),
        _request(command: liveApprovalCommand, cwd: '/tmp'),
        _request(
          command: liveApprovalCommand,
          extra: const {'networkApprovalContext': <String, Object?>{}},
        ),
        _request(
          command: liveApprovalCommand,
          extra: const {'additionalPermissions': <String, Object?>{}},
        ),
        _request(command: null),
        _request(command: liveApprovalCommand, method: 'tool/requestUserInput'),
        _request(command: liveApprovalCommand, threadId: 'thread-2'),
        _request(command: liveApprovalCommand, turnId: 'turn-2'),
        _request(command: liveApprovalCommand, itemId: ''),
        _request(command: liveApprovalCommand, kind: 'network'),
        _request(
          command: liveApprovalCommand,
          availableDecisions: const ['decline', 'cancel'],
        ),
      ]) {
        expect(
          validateLiveCommandApproval(
            request,
            threadId: scope.threadId,
            turnId: scope.turnId,
            cwd: scope.cwd,
          ),
          isNotNull,
        );
      }
    });
  });

  test(
    'local app-server harness validates approval lifecycle end to end',
    () async {
      final server = await MockAppServer.start();
      CodexClient? rpc;
      try {
        rpc = await CodexClient.connect(
          server.uri,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        );
        final invalidFuture = rpc.serverRequests.first;
        server.request(
          30,
          'item/commandExecution/requestApproval',
          _request(command: '$liveApprovalCommand; uname -a').params,
        );
        final invalid = await invalidFuture;
        expect(
          validateLiveCommandApproval(
            invalid,
            threadId: 'thread-1',
            turnId: 'turn-1',
            cwd: '/srv/project',
          ),
          isNotNull,
        );
        expect(rpc.respondApproval(invalid, ApprovalDecision.cancel), isTrue);
        await eventually(
          () => server.received.any(
            (message) =>
                message.value['id'] == 30 &&
                (message.value['result'] as Map?)?['decision'] == 'cancel',
          ),
          timeout: const Duration(seconds: 2),
        );

        final requestFuture = rpc.serverRequests.first;
        final resolvedFuture = rpc.notifications.firstWhere(
          (event) =>
              event.method == 'serverRequest/resolved' &&
              event.params['requestId'] == 31,
        );
        final itemFuture = rpc.itemSnapshots.firstWhere(
          (event) => event.completed && event.itemId == 'item-1',
        );
        final turnFuture = rpc.turnSnapshots.firstWhere(
          (event) => event.completed && event.turn.id == 'turn-1',
        );
        server.request(
          31,
          'item/commandExecution/requestApproval',
          _request(command: liveApprovalCommand).params,
        );
        final request = await requestFuture;
        expect(
          validateLiveCommandApproval(
            request,
            threadId: 'thread-1',
            turnId: 'turn-1',
            cwd: '/srv/project',
          ),
          isNull,
        );
        expect(rpc.respondApproval(request, ApprovalDecision.accept), isTrue);
        await eventually(
          () => server.received.any(
            (message) =>
                message.value['id'] == 31 && message.value['method'] == null,
          ),
          timeout: const Duration(seconds: 2),
        );
        server.notify('serverRequest/resolved', <String, Object?>{
          'threadId': 'thread-1',
          'requestId': 31,
        });
        server.notify('item/completed', <String, Object?>{
          'threadId': 'thread-1',
          'turnId': 'turn-1',
          'item': <String, Object?>{
            'id': 'item-1',
            'type': 'commandExecution',
            'status': 'completed',
            'exitCode': 0,
            'aggregatedOutput': liveApprovalMarker,
          },
        });
        server.notify('turn/completed', <String, Object?>{
          'threadId': 'thread-1',
          'turn': <String, Object?>{
            'id': 'turn-1',
            'status': 'completed',
            'items': <Object?>[],
          },
        });

        expect((await resolvedFuture).params['threadId'], 'thread-1');
        final item = await itemFuture;
        expect(item.item.data['aggregatedOutput'], liveApprovalMarker);
        expect(jsonInt(item.item.data['exitCode']), 0);
        expect((await turnFuture).turn.status, 'completed');
      } finally {
        await rpc?.dispose();
        await server.close();
      }
    },
  );

  test(
    'live VPS: approves one exact harmless command and observes its lifecycle',
    () async {
      final fixture = await loadFixture();
      final cwd = fixture['cwd'] as String;
      SshConnection? ssh;
      CodexTunnel? tunnel;
      CodexClient? rpc;
      StreamSubscription<ServerRequest>? requestSubscription;
      StreamSubscription<RpcNotification>? notificationSubscription;
      StreamSubscription<ItemSnapshot>? itemSubscription;
      StreamSubscription<TurnSnapshot>? turnSubscription;
      String? threadId;
      String? turnId;
      ServerRequest? approval;
      ItemSnapshot? completedItem;
      TurnSnapshot? completedTurn;
      Object? lifecycleFailure;
      var resolved = false;
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
        final account = await rpc.readAccount().timeout(
          const Duration(seconds: 30),
        );
        expect(
          account.isAuthenticated,
          isTrue,
          reason: 'The live Codex runtime must be authenticated',
        );
        final models = await rpc.listModels().timeout(
          const Duration(seconds: 30),
        );
        expect(models.data, isNotEmpty);
        final model = models.data
            .map((item) => item.model)
            .firstWhere(
              (id) => id == 'gpt-5.6-sol',
              orElse: () => models.data.first.model,
            );
        final thread = await rpc
            .startThread(
              cwd: cwd,
              model: model,
              approvalPolicy: CodexApprovalPolicy.onRequest,
              sandbox: CodexSandboxMode.workspaceWrite,
            )
            .timeout(const Duration(seconds: 30));
        threadId = thread.id;

        requestSubscription = rpc.serverRequests.listen((request) {
          try {
            if (approval != null ||
                request.method != 'item/commandExecution/requestApproval') {
              if (request.method == 'item/commandExecution/requestApproval') {
                rpc!.respondApproval(request, ApprovalDecision.cancel);
              } else {
                rpc!.rejectServerRequest(
                  request,
                  message: 'Unexpected request during approval validation',
                );
              }
              lifecycleFailure ??= StateError('unexpected server request');
              return;
            }
            approval = request;
          } catch (_) {
            lifecycleFailure ??= StateError(
              'failed to cancel an unexpected server request',
            );
          }
        });
        notificationSubscription = rpc.notifications.listen((notification) {
          if (notification.method == 'serverRequest/resolved' &&
              approval != null &&
              notification.params['threadId'] == threadId &&
              notification.params['requestId'] == approval!.id) {
            resolved = true;
          }
        });
        itemSubscription = rpc.itemSnapshots.listen((snapshot) {
          if (snapshot.completed &&
              snapshot.threadId == threadId &&
              snapshot.turnId == turnId &&
              snapshot.itemId == approval?.itemId) {
            completedItem = snapshot;
          }
        });
        turnSubscription = rpc.turnSnapshots.listen((snapshot) {
          if (snapshot.completed &&
              snapshot.threadId == threadId &&
              snapshot.turn.id == turnId) {
            completedTurn = snapshot;
            if (approval == null) {
              lifecycleFailure ??= StateError(
                'turn completed without an approval request',
              );
            }
          }
        });

        final startedTurn = await rpc
            .sendMessage(
              thread.id,
              _approvalPrompt(cwd),
              model: model,
              effort: 'low',
            )
            .timeout(const Duration(seconds: 30));
        turnId = startedTurn.id;
        await eventually(
          () => approval != null || lifecycleFailure != null,
          timeout: const Duration(seconds: 45),
        );
        if (lifecycleFailure != null) throw lifecycleFailure!;
        final request = approval!;
        final violation = validateLiveCommandApproval(
          request,
          threadId: thread.id,
          turnId: startedTurn.id,
          cwd: cwd,
        );
        if (violation != null) {
          rpc.respondApproval(request, ApprovalDecision.cancel);
          throw StateError('approval rejected: $violation');
        }
        expect(rpc.respondApproval(request, ApprovalDecision.accept), isTrue);

        await eventually(
          () =>
              lifecycleFailure != null ||
              (resolved && completedItem != null && completedTurn != null),
          timeout: const Duration(seconds: 90),
        );
        if (lifecycleFailure != null) throw lifecycleFailure!;
        expect(completedItem!.item.type, 'commandExecution');
        expect(completedItem!.item.data['status'], 'completed');
        expect(jsonInt(completedItem!.item.data['exitCode']), 0);
        expect(
          completedItem!.item.data['aggregatedOutput'],
          liveApprovalMarker,
        );
        expect(completedTurn!.turn.status, 'completed');

        await rpc.archiveThread(thread.id).timeout(const Duration(seconds: 20));
        archived = true;
      } finally {
        await requestSubscription?.cancel();
        await notificationSubscription?.cancel();
        await itemSubscription?.cancel();
        await turnSubscription?.cancel();
        if (!archived && rpc != null && threadId != null) {
          if (turnId != null) {
            await _bestEffort(
              rpc
                  .interruptTurn(threadId, turnId)
                  .timeout(const Duration(seconds: 10)),
            );
          }
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
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

ServerRequest _request({
  required String? command,
  String method = 'item/commandExecution/requestApproval',
  String threadId = 'thread-1',
  String turnId = 'turn-1',
  String itemId = 'item-1',
  String cwd = '/srv/project',
  String? kind,
  List<String>? availableDecisions,
  Map<String, Object?> extra = const {},
}) => ServerRequest(
  id: 7,
  method: method,
  params: <String, Object?>{
    'threadId': threadId,
    'turnId': turnId,
    'itemId': itemId,
    'startedAtMs': 1,
    'cwd': cwd,
    'command': command,
    'kind': ?kind,
    'availableDecisions': ?availableDecisions,
    ...extra,
  },
);

String _approvalPrompt(String cwd) =>
    '''
Work only inside this working directory: $cwd
Do not read files, environment variables, credentials, or authentication data.
Do not access the network and do not write or modify any file.
Request approval before using the shell exactly once to run this exact command, with no wrapper or additional command:
$liveApprovalCommand
Use the shell tool's approval or escalation mechanism so the app-server sends item/commandExecution/requestApproval.
Do not ask the user for approval in conversational text; only the server-initiated approval request counts.
After it finishes, reply briefly without using any other tool.
''';

Future<void> _bestEffort(Future<Object?>? operation) async {
  if (operation == null) return;
  try {
    await operation;
  } catch (_) {
    // Cleanup is bounded and must not hide the primary failure.
  }
}
