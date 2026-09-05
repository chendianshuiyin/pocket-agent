import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/codex/codex.dart';

void main() {
  test('maps commandExecution aggregatedOutput from the v2 schema', () {
    final item = CodexItem.fromJson({
      'id': 'command-1',
      'type': 'commandExecution',
      'command': 'printf ok',
      'cwd': '/work',
      'status': 'completed',
      'commandActions': <Object?>[],
      'aggregatedOutput': 'line one\n中文 output',
      'internalToken': 'must-not-render',
    });

    final timeline = codexItemToTimeline(item, completed: true);

    expect(timeline.kind, TimelineKind.tool);
    expect(timeline.title, 'printf ok');
    expect(timeline.text, 'line one\n中文 output');
    expect(timeline.text, isNot(contains('internalToken')));
    expect(timeline.text, isNot(contains('must-not-render')));
  });

  test('maps v2 fileChange paths, kinds, moves, and diffs as text', () {
    final item = CodexItem.fromJson({
      'id': 'change-1',
      'type': 'fileChange',
      'status': 'completed',
      'changes': [
        {
          'path': 'lib/old.dart',
          'kind': {'type': 'update', 'move_path': 'lib/new.dart'},
          'diff': '@@ -1 +1 @@\n-old\n+new',
        },
        {
          'path': 'lib/added.dart',
          'kind': {'type': 'add'},
          'diff': '+content',
        },
      ],
    });

    final text = codexItemToTimeline(item, completed: true).text;

    expect(text, contains('update lib/old.dart -> lib/new.dart'));
    expect(text, contains('@@ -1 +1 @@\n-old\n+new'));
    expect(text, contains('add lib/added.dart'));
    expect(text, contains('+content'));
    expect(text, isNot(contains('{type:')));
  });

  test('maps legacy fileChanges without serializing raw maps', () {
    final item = CodexItem.fromJson({
      'id': 'legacy-change-1',
      'type': 'fileChange',
      'fileChanges': {
        'lib/a.dart': {'type': 'update', 'unified_diff': '@@ -1 +1 @@\n-a\n+b'},
      },
    });

    final text = codexItemToTimeline(item, completed: true).text;

    expect(text, 'update lib/a.dart\n@@ -1 +1 @@\n-a\n+b');
    expect(text, isNot(contains('{')));
  });

  test('maps failed turn error.message without raw diagnostic fields', () {
    final turn = CodexTurn.fromJson({
      'id': 'turn-1',
      'status': 'failed',
      'items': <Object?>[],
      'error': {
        'message': 'Sandbox denied the command',
        'additionalDetails': 'private diagnostic detail',
        'codexErrorInfo': {'type': 'SandboxError', 'token': 'must-not-render'},
      },
    });

    final presentation = codexTurnPresentation(turn);

    expect(presentation.state, ThreadRunState.error);
    expect(presentation.error, '任务运行失败：Sandbox denied the command');
    expect(presentation.error, isNot(contains('private diagnostic detail')));
    expect(presentation.error, isNot(contains('must-not-render')));
    expect(presentation.error, isNot(contains('codexErrorInfo')));
  });

  test('failed turn without a protocol message uses a safe fallback', () {
    final turn = CodexTurn.fromJson({
      'id': 'turn-2',
      'status': 'failed',
      'items': <Object?>[],
      'error': {
        'codexErrorInfo': {'token': 'must-not-render'},
      },
    });

    final presentation = codexTurnPresentation(turn);

    expect(presentation.state, ThreadRunState.error);
    expect(presentation.error, '任务运行失败，请重试。');
    expect(presentation.error, isNot(contains('must-not-render')));
  });
}
