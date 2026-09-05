// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';

import 'mock_app_server.dart';

void main() {
  late MockAppServer server;
  CodexClient? client;

  setUp(() async {
    server = await MockAppServer.start();
  });

  tearDown(() async {
    await client?.dispose();
    await server.close();
  });

  test(
    'performs initialize handshake and explicitly lists appServer threads',
    () async {
      server.handler = (message) {
        if (message.value['method'] == 'thread/list') {
          final params = message.value['params']! as Map;
          expect(params['sourceKinds'], <String>['appServer']);
          message.result(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 'thread-1',
                'preview': 'Hello',
                'turns': <Object?>[],
              },
            ],
            'nextCursor': null,
            'backwardsCursor': null,
          });
        }
      };

      client = await CodexClient.connect(
        server.uri,
        reconnectPolicy: const ReconnectPolicy(enabled: false),
      );
      expect(
        await client!.states.first,
        isA<ConnectionSnapshot>().having(
          (state) => state.phase,
          'phase',
          ConnectionPhase.ready,
        ),
      );

      final page = await client!.listThreads();
      expect(page.data.single.id, 'thread-1');
      await server.waitFor('initialized');
      expect(
        server.received.take(3).map((message) => message.value['method']),
        <String>['initialize', 'initialized', 'thread/list'],
      );
    },
  );

  test('replays early notifications and unresolved server requests', () async {
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );
    server.notify('custom/ready', <String, Object?>{'value': 7});
    server.request(
      91,
      'item/commandExecution/requestApproval',
      <String, Object?>{
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'itemId': 'item-1',
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      (await client!.notifications.firstWhere(
        (event) => event.method == 'custom/ready',
      )).params['value'],
      7,
    );
    final approval = await client!.serverRequests.first;
    expect(approval.id, 91);
    client!.respondApproval(approval, ApprovalDecision.acceptForSession);

    final response = await _waitForResponse(server, 91);
    expect((response.value['result']! as Map)['decision'], 'acceptForSession');
  });

  test('reads a redacted signed-out account status without changing thread history', () async {
    server.handler = (message) {
      switch (message.value['method']) {
        case 'thread/start':
          message.result(<String, Object?>{
            'thread': <String, Object?>{
              'id': 'thread-1',
              'preview': 'Keep me',
              'turns': <Object?>[],
            },
          });
        case 'account/read':
          final params = message.value['params']! as Map;
          expect(params['refreshToken'], isFalse);
          message.result(<String, Object?>{
            'account': null,
            'requiresOpenaiAuth': true,
          });
      }
    };
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );
    await client!.startThread();

    final account = await client!.readAccount();
    expect(account.isAuthenticated, isFalse);
    expect(account.requiresOpenaiAuth, isTrue);
    expect(account.kind, AccountKind.signedOut);
    expect(client!.activeThreadId, 'thread-1');
    expect((await client!.threadSnapshots.first).thread.preview, 'Keep me');
  });

  test(
    'maps request-user-input answers and removes the resolved request',
    () async {
      client = await CodexClient.connect(
        server.uri,
        reconnectPolicy: const ReconnectPolicy(enabled: false),
      );
      server.request(92, 'item/tool/requestUserInput', <String, Object?>{
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'itemId': 'item-1',
        'questions': <Object?>[],
        'autoResolutionMs': null,
      });
      final request = await client!.serverRequests.first;
      client!.respondUserInput(request, <String, List<String>>{
        'choice': <String>['Other answer'],
      });
      final response = await _waitForResponse(server, 92);
      expect(
        (((response.value['result']! as Map)['answers']! as Map)['choice']!
            as Map)['answers'],
        <String>['Other answer'],
      );
      server.notify('serverRequest/resolved', <String, Object?>{
        'threadId': 'thread-1',
        'requestId': 92,
      });
    },
  );

  test('matches out-of-order responses and surfaces rpc errors', () async {
    final calls = <MockRpcMessage>[];
    server.handler = (message) {
      if (message.value['method'] == 'first' ||
          message.value['method'] == 'second') {
        calls.add(message);
        if (calls.length == 2) {
          calls[1].result('two');
          calls[0].result('one');
        }
      } else if (message.value['method'] == 'failure') {
        message.error(
          -32602,
          'bad params',
          data: <String, Object?>{'field': 'cwd'},
        );
      }
    };
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );

    final first = client!.request('first', const <String, Object?>{});
    final second = client!.request('second', const <String, Object?>{});
    expect(await Future.wait(<Future<Object?>>[first, second]), <Object?>[
      'one',
      'two',
    ]);
    await expectLater(
      client!.request('failure', const <String, Object?>{}),
      throwsA(
        isA<RpcException>().having((error) => error.code, 'code', -32602),
      ),
    );
  });

  test('times out and supports client-side request cancellation', () async {
    client = await CodexClient.connect(
      server.uri,
      requestTimeout: const Duration(milliseconds: 30),
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );
    await expectLater(
      client!.request('never', const <String, Object?>{}),
      throwsA(isA<RpcTimeoutException>()),
    );

    final token = RpcCancellationToken();
    final pending = client!.request(
      'cancel-me',
      const <String, Object?>{},
      timeout: const Duration(seconds: 1),
      cancellationToken: token,
    );
    token.cancel();
    await expectLater(pending, throwsA(isA<RpcCancelledException>()));
  });

  test(
    'aggregates deltas and treats item/completed as authoritative',
    () async {
      client = await CodexClient.connect(
        server.uri,
        reconnectPolicy: const ReconnectPolicy(enabled: false),
      );
      server.notify('item/started', <String, Object?>{
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'type': 'agentMessage',
          'id': 'item-1',
          'text': '',
        },
      });
      server.notify('item/agentMessage/delta', <String, Object?>{
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'itemId': 'item-1',
        'delta': 'streamed',
      });
      server.notify('item/completed', <String, Object?>{
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'type': 'agentMessage',
          'id': 'item-1',
          'text': 'authoritative',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final snapshot = await client!.itemSnapshots.firstWhere(
        (event) => event.completed,
      );
      expect(snapshot.item.data['text'], 'authoritative');
      expect(snapshot.revision, 3);
    },
  );

  test('bounds a long streamed item field', () async {
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );
    server.notify('item/commandExecution/outputDelta', <String, Object?>{
      'threadId': 'thread-1',
      'turnId': 'turn-1',
      'itemId': 'item-1',
      'delta': 'x' * (300 * 1024),
    });

    final snapshot = await client!.itemSnapshots.first;
    expect(
      (snapshot.item.data['aggregatedOutput']! as String).length,
      256 * 1024,
    );
    expect(snapshot.item.data['_streamTruncated'], isTrue);
  });

  test(
    'reconnect reads and resumes active thread without replaying turn/start',
    () async {
      server.handler = (message) {
        switch (message.value['method']) {
          case 'thread/start':
            message.result(<String, Object?>{
              'thread': <String, Object?>{
                'id': 'thread-1',
                'turns': <Object?>[],
              },
            });
          case 'thread/read':
            message.result(<String, Object?>{
              'thread': <String, Object?>{
                'id': 'thread-1',
                'preview': 'Recovered',
                'turns': <Object?>[
                  <String, Object?>{
                    'id': 'old-turn',
                    'status': 'completed',
                    'items': <Object?>[],
                  },
                ],
              },
            });
          case 'thread/resume':
            message.result(<String, Object?>{
              'thread': <String, Object?>{
                'id': 'thread-1',
                'turns': <Object?>[],
              },
            });
        }
      };
      client = await CodexClient.connect(
        server.uri,
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(milliseconds: 10),
        ),
      );
      await client!.startThread();
      await server.closeConnections();

      final recovered = await client!.threadSnapshots
          .firstWhere(
            (snapshot) =>
                snapshot.recovered && snapshot.thread.preview == 'Recovered',
          )
          .timeout(const Duration(seconds: 2));
      await server.waitFor('thread/resume');
      expect(recovered.thread.turns.single.id, 'old-turn');
      expect(server.connectionCount, greaterThanOrEqualTo(2));
      expect(
        server.received.where(
          (message) => message.value['method'] == 'thread/start',
        ),
        hasLength(1),
      );
      expect(
        server.received.where(
          (message) => message.value['method'] == 'thread/read',
        ),
        isNotEmpty,
      );
      expect(
        server.received.where(
          (message) => message.value['method'] == 'thread/resume',
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'bounds automatic reconnect attempts and permits a manual retry',
    () async {
      var connectorCalls = 0;
      var rejectConnections = false;
      final exhausted = Completer<void>();
      Future<WebSocket> connector(Uri uri, Map<String, String> headers) {
        connectorCalls += 1;
        if (rejectConnections) {
          if (connectorCalls >= 3 && !exhausted.isCompleted)
            exhausted.complete();
          return Future<WebSocket>.error(const SocketException('offline'));
        }
        return WebSocket.connect(uri.toString(), headers: headers);
      }

      client = await CodexClient.connect(
        server.uri,
        socketConnector: connector,
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 5),
          maxAttempts: 2,
        ),
      );
      rejectConnections = true;
      await server.closeConnections();
      await exhausted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connectorCalls, 3);
      expect(client!.state.phase, ConnectionPhase.disconnected);
      expect(client!.state.attempt, 2);

      rejectConnections = false;
      await client!.reconnect();
      expect(client!.state.phase, ConnectionPhase.ready);
      expect(connectorCalls, 4);
    },
  );

  test('clears stale server requests when the connection drops', () async {
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(
        initialDelay: Duration(milliseconds: 5),
        maxAttempts: 1,
      ),
    );
    server.request(101, 'item/fileChange/requestApproval', <String, Object?>{
      'threadId': 'thread-1',
      'turnId': 'turn-1',
      'itemId': 'item-1',
    });
    expect((await client!.serverRequests.first).id, 101);
    await server.closeConnections();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await expectLater(
      client!.serverRequests.first.timeout(const Duration(milliseconds: 30)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('uses 0.153.4 thread sandbox and explicit skill wire formats', () async {
    server.handler = (message) {
      switch (message.value['method']) {
        case 'thread/start':
          message.result(<String, Object?>{
            'thread': <String, Object?>{'id': 'thread-1', 'turns': <Object?>[]},
          });
        case 'turn/start':
          message.result(<String, Object?>{
            'turn': <String, Object?>{
              'id': 'turn-1',
              'status': 'inProgress',
              'items': <Object?>[],
            },
          });
      }
    };
    client = await CodexClient.connect(
      server.uri,
      reconnectPolicy: const ReconnectPolicy(enabled: false),
    );
    await client!.startThread(
      sandbox: CodexSandboxMode.workspaceWrite,
      approvalPolicy: CodexApprovalPolicy.onRequest,
    );
    const skill = SkillMetadata(
      name: 'skill-creator',
      description: 'Create skills',
      path: '/tmp/SKILL.md',
      scope: 'user',
      enabled: true,
      raw: <String, Object?>{},
    );
    await client!.sendMessage(
      'thread-1',
      'Create one',
      skill: skill,
      sandboxPolicy: const CodexSandboxPolicy.workspaceWrite(
        writableRoots: <String>['/tmp/project'],
      ),
    );

    final threadStart =
        (await server.waitFor('thread/start')).single.value['params']! as Map;
    expect(threadStart['sandbox'], 'workspace-write');
    expect(threadStart['approvalPolicy'], 'on-request');
    final turnStart =
        (await server.waitFor('turn/start')).single.value['params']! as Map;
    final input = turnStart['input']! as List;
    expect((input[0] as Map)['text'], r'$skill-creator Create one');
    expect(input[1], <String, Object?>{
      'type': 'skill',
      'name': 'skill-creator',
      'path': '/tmp/SKILL.md',
    });
    expect((turnStart['sandboxPolicy']! as Map)['type'], 'workspaceWrite');
  });

  test(
    'uses native skills, compact, review, interrupt, and archive methods',
    () async {
      server.handler = (message) {
        switch (message.value['method']) {
          case 'skills/list':
            message.result(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'cwd': '/work',
                  'skills': <Object?>[
                    <String, Object?>{
                      'name': 'docs',
                      'description': 'Read docs',
                      'path': '/skills/docs/SKILL.md',
                      'scope': 'user',
                      'enabled': true,
                    },
                  ],
                  'errors': <Object?>[],
                },
              ],
            });
          case 'thread/compact/start':
          case 'turn/interrupt':
          case 'thread/archive':
            message.result(<String, Object?>{});
          case 'review/start':
            message.result(<String, Object?>{
              'turn': <String, Object?>{
                'id': 'review-turn',
                'status': 'inProgress',
                'items': <Object?>[],
              },
              'reviewThreadId': 'thread-1',
            });
        }
      };
      client = await CodexClient.connect(
        server.uri,
        reconnectPolicy: const ReconnectPolicy(enabled: false),
      );

      final skills = await client!.listSkills(
        cwds: <String>['/work'],
        forceReload: true,
      );
      expect(skills.single.skills.single.name, 'docs');
      await client!.compactThread('thread-1');
      final review = await client!.reviewUncommittedChanges('thread-1');
      await client!.interruptTurn('thread-1', 'turn-1');
      await client!.archiveThread('thread-1');

      expect(review.reviewThreadId, 'thread-1');
      final skillParams =
          (await server.waitFor('skills/list')).single.value['params']! as Map;
      expect(skillParams, <String, Object?>{
        'cwds': <String>['/work'],
        'forceReload': true,
      });
      final reviewParams =
          (await server.waitFor('review/start')).single.value['params']! as Map;
      expect(reviewParams['target'], <String, Object?>{
        'type': 'uncommittedChanges',
      });
      expect(reviewParams['delivery'], 'inline');
      expect(
        (await server.waitFor('thread/compact/start')).single.value['params'],
        <String, Object?>{'threadId': 'thread-1'},
      );
      expect(
        (await server.waitFor('turn/interrupt')).single.value['params'],
        <String, Object?>{'threadId': 'thread-1', 'turnId': 'turn-1'},
      );
      expect(
        (await server.waitFor('thread/archive')).single.value['params'],
        <String, Object?>{'threadId': 'thread-1'},
      );
    },
  );

  test('rejects non-loopback endpoints', () async {
    await expectLater(
      CodexClient.connect(Uri.parse('ws://example.com:4500')),
      throwsArgumentError,
    );
  });
}

Future<MockRpcMessage> _waitForResponse(MockAppServer server, Object id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    for (final message in server.received) {
      if (message.value['method'] == null && message.value['id'] == id)
        return message;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('Did not receive response $id');
}
