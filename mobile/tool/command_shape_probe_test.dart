import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';

import '../test/live_vps_test.dart'
    show fixtureToken, loadFixture, makeConnection;

const _recoveryCommand = "sleep 8 && printf '__POCKET_RECOVERY_COMMAND__\\n'";
const _interruptCommand =
    "sleep 30 && printf '__POCKET_INTERRUPT_UNEXPECTED__\\n'";

const _baseKinds = <String>['recovery', 'interrupt'];
const _shapeKinds = <String>[
  'noWrapper',
  'bashC.doubleQuote',
  'bashC.doubleQuoteBackslashDoubled',
  'bashC.singleQuote',
  'bashLc.doubleQuote',
  'bashLc.doubleQuoteBackslashDoubled',
  'bashLc.singleQuote',
  'shC.doubleQuote',
  'shC.doubleQuoteBackslashDoubled',
  'shC.singleQuote',
];
const _unmatchedKinds = <String>[
  'missingCommand',
  'nonStringCommand',
  'otherString',
];

void main() {
  test(
    'live VPS: safely classify stored command wrapper shapes',
    () async {
      final fixture = await loadFixture();
      final cwd = fixture['cwd'] as String;
      final ssh = makeConnection(fixture);
      CodexTunnel? tunnel;
      CodexClient? rpc;

      try {
        await ssh.connect(onFirstUseHostKey: (_) async => false);
        tunnel = await RemoteRuntimeManager(ssh).openExistingTunnel();
        rpc = await CodexClient.connect(
          tunnel.uri,
          headers: tunnel.clientHeaders,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        );

        final results = <_ArchiveProbeResult>[];
        for (final archived in <bool>[false, true]) {
          results.add(await _probeArchiveScope(rpc, cwd, archived: archived));
        }
        for (final result in results) {
          for (final summary in result.safeSummaries) {
            // All labels and values are fixed enums or aggregate counts.
            // ignore: avoid_print
            print(summary);
          }
        }
        expect(
          results.any((result) => result.listSucceeded),
          isTrue,
          reason: 'At least one bounded thread/list probe must succeed',
        );
      } finally {
        await rpc?.dispose();
        await tunnel?.close();
        await ssh.disconnect();
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<_ArchiveProbeResult> _probeArchiveScope(
  CodexClient rpc,
  String cwd, {
  required bool archived,
}) async {
  late final JsonMap response;
  try {
    response = jsonMap(
      await rpc.request('thread/list', <String, Object?>{
        'limit': 20,
        'cwd': cwd,
        'archived': archived,
        'sortKey': 'updated_at',
        'sortDirection': 'desc',
        'sourceKinds': <String>['appServer', 'vscode'],
      }),
    );
  } on RpcException catch (error) {
    return _ArchiveProbeResult.listFailure(
      archived: archived,
      listFailureKind: 'rpc',
      listRpcCode: error.code,
    );
  } catch (_) {
    return _ArchiveProbeResult.listFailure(
      archived: archived,
      listFailureKind: 'unexpected',
    );
  }

  final result = _ArchiveProbeResult.success(
    archived: archived,
    threadCount: jsonList(response['data']).length,
    hasNextCursor: jsonString(response['nextCursor']) != null,
  );
  final seenThreadIds = <String>{};
  for (final value in jsonList(response['data'])) {
    final threadId = jsonString(jsonMap(value)['id']);
    if (threadId == null || threadId.isEmpty) {
      result.invalidThreadIds += 1;
      continue;
    }
    if (!seenThreadIds.add(threadId)) continue;
    try {
      final thread = await rpc
          .readThread(threadId, includeTurns: true)
          .timeout(const Duration(seconds: 10));
      result.successfulReads += 1;
      for (final turn in thread.turns) {
        for (final item in turn.items) {
          if (item.type != 'commandExecution') continue;
          result.commandItems += 1;
          result.observeCommand(item.data);
        }
      }
    } on RpcException catch (_) {
      result.rpcReadFailures += 1;
    } catch (_) {
      result.unexpectedReadFailures += 1;
    }
  }
  return result;
}

final class _ArchiveProbeResult {
  _ArchiveProbeResult.success({
    required this.archived,
    required this.threadCount,
    required this.hasNextCursor,
  }) : listSucceeded = true,
       listFailureKind = null,
       listRpcCode = null,
       baseCounts = <String, int>{for (final kind in _baseKinds) kind: 0},
       shapeCounts = <String, int>{for (final kind in _shapeKinds) kind: 0},
       unmatchedCounts = <String, int>{
         for (final kind in _unmatchedKinds) kind: 0,
       };

  _ArchiveProbeResult.listFailure({
    required this.archived,
    required this.listFailureKind,
    this.listRpcCode,
  }) : listSucceeded = false,
       threadCount = 0,
       hasNextCursor = false,
       baseCounts = const <String, int>{},
       shapeCounts = const <String, int>{},
       unmatchedCounts = const <String, int>{};

  final bool archived;
  final bool listSucceeded;
  final int threadCount;
  final bool hasNextCursor;
  final String? listFailureKind;
  final int? listRpcCode;
  final Map<String, int> baseCounts;
  final Map<String, int> shapeCounts;
  final Map<String, int> unmatchedCounts;
  var invalidThreadIds = 0;
  var successfulReads = 0;
  var rpcReadFailures = 0;
  var unexpectedReadFailures = 0;
  var commandItems = 0;

  void observeCommand(JsonMap item) {
    final rawCommand = item['command'];
    if (rawCommand == null) {
      unmatchedCounts['missingCommand'] =
          unmatchedCounts['missingCommand']! + 1;
      return;
    }
    if (rawCommand is! String) {
      unmatchedCounts['nonStringCommand'] =
          unmatchedCounts['nonStringCommand']! + 1;
      return;
    }
    final classification = _knownCommands[rawCommand];
    if (classification == null) {
      unmatchedCounts['otherString'] = unmatchedCounts['otherString']! + 1;
      return;
    }
    baseCounts[classification.base] = baseCounts[classification.base]! + 1;
    shapeCounts[classification.shape] = shapeCounts[classification.shape]! + 1;
  }

  Iterable<String> get safeSummaries sync* {
    final scope = 'archived=$archived';
    if (!listSucceeded) {
      yield 'COMMAND_SHAPE_PROBE $scope listOk=false '
          'failure=$listFailureKind rpcCode=${listRpcCode ?? "none"}';
      return;
    }
    yield 'COMMAND_SHAPE_PROBE $scope listOk=true threads=$threadCount '
        'nextCursor=$hasNextCursor readsOk=$successfulReads '
        'readRpcFailures=$rpcReadFailures '
        'readUnexpectedFailures=$unexpectedReadFailures '
        'invalidThreadIds=$invalidThreadIds commandItems=$commandItems';
    yield 'COMMAND_SHAPE_BASE $scope ${_formatCounts(baseCounts)}';
    yield 'COMMAND_SHAPE_COUNTS $scope ${_formatCounts(shapeCounts)}';
    yield 'COMMAND_SHAPE_UNMATCHED $scope '
        'total=${unmatchedCounts.values.fold<int>(0, (sum, value) => sum + value)} '
        '${_formatCounts(unmatchedCounts)}';
  }
}

final class _CommandClassification {
  const _CommandClassification(this.base, this.shape);

  final String base;
  final String shape;
}

final _knownCommands = _buildKnownCommands();

Map<String, _CommandClassification> _buildKnownCommands() {
  final known = <String, _CommandClassification>{};
  for (final command in <({String base, String value})>[
    (base: 'recovery', value: _recoveryCommand),
    (base: 'interrupt', value: _interruptCommand),
  ]) {
    void add(String value, String shape) {
      known[value] = _CommandClassification(command.base, shape);
    }

    add(command.value, 'noWrapper');
    for (final shell in <({String executable, String flag, String label})>[
      (executable: '/bin/bash', flag: '-c', label: 'bashC'),
      (executable: '/bin/bash', flag: '-lc', label: 'bashLc'),
      (executable: '/bin/sh', flag: '-c', label: 'shC'),
    ]) {
      add(
        '${shell.executable} ${shell.flag} "${command.value}"',
        '${shell.label}.doubleQuote',
      );
      add(
        '${shell.executable} ${shell.flag} '
            '"${command.value.replaceAll(r'\', r'\\')}"',
        '${shell.label}.doubleQuoteBackslashDoubled',
      );
      add(
        '${shell.executable} ${shell.flag} ${_quoteForShell(command.value)}',
        '${shell.label}.singleQuote',
      );
    }
  }
  return Map<String, _CommandClassification>.unmodifiable(known);
}

String _quoteForShell(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _formatCounts(Map<String, int> counts) =>
    counts.entries.map((entry) => '${entry.key}:${entry.value}').join(',');
