import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const fixtureToken = String.fromEnvironment('POCKET_FIXTURE_TOKEN');
const fixturePort = String.fromEnvironment(
  'POCKET_FIXTURE_PORT',
  defaultValue: '18089',
);

Future<Map<String, Object?>> loadFixture() async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(
      Uri.parse('http://127.0.0.1:$fixturePort/config'),
    );
    request.headers.set('Authorization', 'Bearer $fixtureToken');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('Private fixture unavailable');
    }
    final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
      all.addAll(chunk);
      return all;
    });
    final body = utf8.decode(bytes);
    return (jsonDecode(body) as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );
  } finally {
    http.close(force: true);
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Expected UI state was not reached');
    }
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> tapWhenHitTestable(
  WidgetTester tester,
  Finder target, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final hitTarget = target.hitTestable();
  await pumpUntil(
    tester,
    () => hitTarget.evaluate().isNotEmpty,
    timeout: timeout,
  );
  await tester.tap(hitTarget);
}

String fixtureString(Map<String, Object?> fixture, String key) {
  final value = fixture[key];
  if (value is! String || value.isEmpty) {
    throw StateError('Private fixture is incomplete');
  }
  return value;
}

int fixtureInt(Map<String, Object?> fixture, String key) {
  final value = fixture[key];
  if (value is! int) throw StateError('Private fixture is incomplete');
  return value;
}

bool registerFixtureTextInput(WidgetTester tester) {
  if (tester.testTextInput.isRegistered) return false;
  tester.testTextInput.register();
  return true;
}

Future<void> enterTerminalCommand(
  WidgetTester tester,
  Finder terminal,
  String command,
) async {
  await tapWhenHitTestable(tester, terminal);
  await pumpUntil(
    tester,
    () => tester.testTextInput.hasAnyClients,
    timeout: const Duration(seconds: 5),
  );
  final initialText = tester.testTextInput.editingState?['text'];
  if (initialText is! String) {
    throw StateError('Terminal text input is not initialized');
  }

  // xterm uses a custom TextInputClient instead of an EditableText widget.
  tester.testTextInput.enterText('$initialText$command');
  await tester.idle();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.idle();
}
