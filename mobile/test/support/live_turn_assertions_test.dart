import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';

import 'live_turn_assertions.dart';

void main() {
  const marker = '__POCKET_ASSERTION_MARKER__';

  test('agent marker must come from agentMessage text', () {
    final promptOnly = _turn(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'user-1',
        'type': 'userMessage',
        'content': marker,
      },
    ]);
    final response = _turn(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'agent-1',
        'type': 'agentMessage',
        'text': marker,
      },
    ]);

    expect(agentMessageTextContains(promptOnly, marker), isFalse);
    expect(agentMessageTextContains(response, marker), isTrue);
  });

  test('command marker must come from successful aggregated output', () {
    final commandOnly = _turn(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'command-1',
        'type': 'commandExecution',
        'command': "printf '$marker'",
        'status': 'completed',
        'exitCode': 0,
        'aggregatedOutput': '',
      },
    ]);
    final output = _turn(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'command-1',
        'type': 'commandExecution',
        'command': 'printf marker',
        'status': 'completed',
        'exitCode': 0,
        'aggregatedOutput': marker,
      },
    ]);

    expect(successfulCommandOutputContains(commandOnly, marker), isFalse);
    expect(successfulCommandOutputContains(output, marker), isTrue);
  });

  test('command output requires completed status and zero exit code', () {
    for (final item in <Map<String, Object?>>[
      <String, Object?>{
        'id': 'command-1',
        'type': 'commandExecution',
        'status': 'failed',
        'exitCode': 0,
        'aggregatedOutput': marker,
      },
      <String, Object?>{
        'id': 'command-2',
        'type': 'commandExecution',
        'status': 'completed',
        'exitCode': 1,
        'aggregatedOutput': marker,
      },
    ]) {
      expect(
        successfulCommandOutputContains(
          _turn(<Map<String, Object?>>[item]),
          marker,
        ),
        isFalse,
      );
    }
  });
}

CodexTurn _turn(List<Map<String, Object?>> items) => CodexTurn.fromJson(
  <String, Object?>{'id': 'turn-1', 'status': 'completed', 'items': items},
);
