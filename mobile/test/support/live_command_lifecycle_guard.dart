import 'package:pocket_agent/codex/codex.dart';

final class LiveCommandLifecycleGuard {
  LiveCommandLifecycleGuard({
    required this.threadId,
    required this.expectedCommand,
  });

  final String threadId;
  final String expectedCommand;
  final List<_CommandEvent> _startedCommands = <_CommandEvent>[];
  final Set<_ItemKey> _completedItems = <_ItemKey>{};
  final Set<String> _completedTurns = <String>{};

  void handle(RpcNotification notification) {
    final params = notification.params;
    if (params['threadId'] != threadId) return;
    final turnId =
        jsonString(params['turnId']) ??
        jsonString(jsonMap(params['turn'])['id']);
    if (turnId == null || turnId.isEmpty) return;

    if (notification.method == 'turn/completed') {
      _completedTurns.add(turnId);
      return;
    }
    if (notification.method != 'item/started' &&
        notification.method != 'item/completed') {
      return;
    }

    final item = jsonMap(params['item']);
    final itemId = jsonString(item['id']) ?? jsonString(params['itemId']);
    if (itemId == null || itemId.isEmpty) return;
    final key = _ItemKey(turnId, itemId);
    if (notification.method == 'item/completed') {
      _completedItems.add(key);
      return;
    }
    if (item['type'] != 'commandExecution') return;
    _startedCommands.add(
      _CommandEvent(
        key: key,
        command: jsonString(item['command']),
        status: jsonString(item['status']),
      ),
    );
  }

  bool hasRelevantLifecycle(String turnId) =>
      _startedCommands.any((event) => event.key.turnId == turnId) ||
      _completedTurns.contains(turnId);

  String? validateInFlight(String turnId) {
    final commands = _startedCommands
        .where((event) => event.key.turnId == turnId)
        .toList(growable: false);
    if (_completedTurns.contains(turnId)) {
      return 'target turn completed before transport shutdown';
    }
    if (commands.isEmpty) return 'target command did not start';
    if (commands.length != 1) return 'unexpected command count';
    final command = commands.single;
    if (!_allowedCommands(expectedCommand).contains(command.command)) {
      return 'unexpected command';
    }
    if (command.status != null && command.status != 'inProgress') {
      return 'target command was not in progress when started';
    }
    if (_completedItems.contains(command.key)) {
      return 'target command completed before transport shutdown';
    }
    return null;
  }
}

Set<String> _allowedCommands(String command) => <String>{
  command,
  '/bin/bash -c "$command"',
  '/bin/bash -lc "$command"',
  '/bin/bash -lc "${command.replaceAll(r'\', r'\\')}"',
  '/bin/sh -c "$command"',
};

final class _CommandEvent {
  const _CommandEvent({
    required this.key,
    required this.command,
    required this.status,
  });

  final _ItemKey key;
  final String? command;
  final String? status;
}

final class _ItemKey {
  const _ItemKey(this.turnId, this.itemId);

  final String turnId;
  final String itemId;

  @override
  bool operator ==(Object other) =>
      other is _ItemKey && turnId == other.turnId && itemId == other.itemId;

  @override
  int get hashCode => Object.hash(turnId, itemId);
}
