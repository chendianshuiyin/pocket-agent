import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';

import 'live_command_lifecycle_guard.dart';

void main() {
  const command = "sleep 20 && printf '__MARKER__\\n'";

  test('accepts the exact in-flight command and known shell wrappers', () {
    for (final observed in <String>[
      command,
      '/bin/bash -c "$command"',
      '/bin/bash -lc "$command"',
      '/bin/bash -lc "${command.replaceAll(r'\', r'\\')}"',
      '/bin/sh -c "$command"',
    ]) {
      final guard = _guard();
      guard.handle(_item('item/started', command: observed));
      expect(guard.validateInFlight('turn-1'), isNull);
    }
  });

  test('rejects an early-completed command or turn', () {
    final completedCommand = _guard();
    completedCommand
      ..handle(_item('item/started'))
      ..handle(_item('item/completed'));
    expect(completedCommand.validateInFlight('turn-1'), isNotNull);

    final completedTurn = _guard();
    completedTurn
      ..handle(_item('item/started'))
      ..handle(
        const RpcNotification('turn/completed', <String, Object?>{
          'threadId': 'thread-1',
          'turn': <String, Object?>{
            'id': 'turn-1',
            'status': 'completed',
            'items': <Object?>[],
          },
        }),
      );
    expect(completedTurn.validateInFlight('turn-1'), isNotNull);

    final completedAtStart = _guard();
    completedAtStart.handle(_item('item/started', status: 'completed'));
    expect(completedAtStart.validateInFlight('turn-1'), isNotNull);
  });

  test('rejects a command without the expected sleep', () {
    final guard = _guard();
    guard.handle(_item('item/started', command: "printf '__MARKER__\\n'"));
    expect(guard.validateInFlight('turn-1'), isNotNull);
  });

  test('rejects altered commands inside the verified bash wrapper', () {
    final escaped = command.replaceAll(r'\', r'\\');
    for (final observed in <String>[
      '/bin/bash -lc "$escaped && printf extra"',
      '/bin/bash -lc "printf \'__MARKER__\\\\n\'"',
    ]) {
      final guard = _guard();
      guard.handle(_item('item/started', command: observed));
      expect(guard.validateInFlight('turn-1'), isNotNull);
    }
  });

  test('other thread, turn, and item events do not count', () {
    final guard = _guard();
    guard
      ..handle(_item('item/started', threadId: 'thread-other'))
      ..handle(_item('item/started', turnId: 'turn-other'));
    expect(guard.hasRelevantLifecycle('turn-1'), isFalse);
    expect(guard.validateInFlight('turn-1'), isNotNull);

    guard
      ..handle(_item('item/started'))
      ..handle(_item('item/completed', itemId: 'item-other'));
    expect(guard.validateInFlight('turn-1'), isNull);
  });
}

LiveCommandLifecycleGuard _guard() => LiveCommandLifecycleGuard(
  threadId: 'thread-1',
  expectedCommand: "sleep 20 && printf '__MARKER__\\n'",
);

RpcNotification _item(
  String method, {
  String threadId = 'thread-1',
  String turnId = 'turn-1',
  String itemId = 'item-1',
  String command = "sleep 20 && printf '__MARKER__\\n'",
  String status = 'inProgress',
}) => RpcNotification(method, <String, Object?>{
  'threadId': threadId,
  'turnId': turnId,
  'item': <String, Object?>{
    'id': itemId,
    'type': 'commandExecution',
    'command': command,
    'status': status,
  },
});
