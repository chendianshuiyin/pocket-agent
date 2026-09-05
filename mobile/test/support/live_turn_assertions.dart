import 'package:pocket_agent/codex/codex.dart';

bool agentMessageTextContains(CodexTurn turn, String marker) => turn.items.any(
  (item) =>
      item.type == 'agentMessage' &&
      item.data['text'] is String &&
      (item.data['text'] as String).contains(marker),
);

bool successfulCommandOutputContains(CodexTurn turn, String marker) =>
    turn.items.any(
      (item) =>
          item.type == 'commandExecution' &&
          item.data['status'] == 'completed' &&
          jsonInt(item.data['exitCode']) == 0 &&
          item.data['aggregatedOutput'] is String &&
          (item.data['aggregatedOutput'] as String).contains(marker),
    );
