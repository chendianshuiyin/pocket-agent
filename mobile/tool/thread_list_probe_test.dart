import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';

import '../test/live_vps_test.dart'
    show fixtureToken, loadFixture, makeConnection;

const _officialSourceKinds = <String>[
  'cli',
  'vscode',
  'exec',
  'appServer',
  'subAgent',
  'subAgentReview',
  'subAgentCompact',
  'subAgentThreadSpawn',
  'subAgentOther',
  'unknown',
];

const _sourceGroups = <String, List<String>>{
  'appServer': <String>['appServer'],
  'allOfficial': _officialSourceKinds,
  'cliVscode': <String>['cli', 'vscode'],
};

void main() {
  test(
    'live VPS: safely probe thread/list source and cwd filters',
    () async {
      final fixture = await loadFixture();
      final fixtureCwd = fixture['cwd'] as String;
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

        final results = <_ProbeResult>[];
        for (final scope in <({String label, String? cwd})>[
          (label: 'fixtureCwd', cwd: fixtureCwd),
          (label: 'noCwd', cwd: null),
        ]) {
          for (final sources in _sourceGroups.entries) {
            results.add(
              await _probeThreadList(
                rpc,
                scopeLabel: scope.label,
                cwd: scope.cwd,
                fixtureCwd: fixtureCwd,
                sourceGroupLabel: sources.key,
                sourceKinds: sources.value,
              ),
            );
          }
        }

        for (final result in results) {
          // This deliberately prints only aggregate, allow-listed statistics.
          // ignore: avoid_print
          print(result.safeSummary);
        }
        expect(
          results.any((result) => result.succeeded),
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
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<_ProbeResult> _probeThreadList(
  CodexClient rpc, {
  required String scopeLabel,
  required String? cwd,
  required String fixtureCwd,
  required String sourceGroupLabel,
  required List<String> sourceKinds,
}) async {
  try {
    final params = <String, Object?>{
      'limit': 100,
      'archived': false,
      'sortKey': 'updated_at',
      'sortDirection': 'desc',
      'sourceKinds': sourceKinds,
    };
    if (cwd != null) params['cwd'] = cwd;
    final response = jsonMap(await rpc.request('thread/list', params));
    final threads = jsonList(response['data']).map(jsonMap).toList();
    return _ProbeResult.success(
      scopeLabel: scopeLabel,
      sourceGroupLabel: sourceGroupLabel,
      threads: threads,
      fixtureCwd: fixtureCwd,
      hasNextCursor: jsonString(response['nextCursor']) != null,
    );
  } on RpcException catch (error) {
    return _ProbeResult.failure(
      scopeLabel: scopeLabel,
      sourceGroupLabel: sourceGroupLabel,
      failureKind: 'rpc',
      rpcCode: error.code,
    );
  } catch (_) {
    return _ProbeResult.failure(
      scopeLabel: scopeLabel,
      sourceGroupLabel: sourceGroupLabel,
      failureKind: 'unexpected',
    );
  }
}

final class _ProbeResult {
  _ProbeResult.success({
    required this.scopeLabel,
    required this.sourceGroupLabel,
    required List<JsonMap> threads,
    required String fixtureCwd,
    required this.hasNextCursor,
  }) : succeeded = true,
       failureKind = null,
       rpcCode = null,
       count = threads.length,
       sourceCounts = _countSources(threads),
       ephemeralCounts = _countBooleans(threads, 'ephemeral'),
       cwdCounts = _countCwds(threads, fixtureCwd);

  _ProbeResult.failure({
    required this.scopeLabel,
    required this.sourceGroupLabel,
    required this.failureKind,
    this.rpcCode,
  }) : succeeded = false,
       hasNextCursor = false,
       count = 0,
       sourceCounts = const <String, int>{},
       ephemeralCounts = const <String, int>{},
       cwdCounts = const <String, int>{};

  final String scopeLabel;
  final String sourceGroupLabel;
  final bool succeeded;
  final bool hasNextCursor;
  final int count;
  final Map<String, int> sourceCounts;
  final Map<String, int> ephemeralCounts;
  final Map<String, int> cwdCounts;
  final String? failureKind;
  final int? rpcCode;

  String get safeSummary {
    final prefix =
        'THREAD_LIST_PROBE scope=$scopeLabel sources=$sourceGroupLabel';
    if (!succeeded) {
      return '$prefix ok=false failure=$failureKind '
          'rpcCode=${rpcCode ?? "none"}';
    }
    return '$prefix ok=true count=$count nextCursor=$hasNextCursor '
        'sourceCounts=${_formatCounts(sourceCounts)} '
        'ephemeral=${_formatCounts(ephemeralCounts)} '
        'cwd=${_formatCounts(cwdCounts)}';
  }
}

Map<String, int> _countSources(List<JsonMap> threads) {
  final counts = <String, int>{
    for (final source in _officialSourceKinds) source: 0,
    'missingOrUnrecognized': 0,
  };
  for (final thread in threads) {
    final source = _sourceKind(thread);
    final key = source != null && _officialSourceKinds.contains(source)
        ? source
        : 'missingOrUnrecognized';
    counts[key] = counts[key]! + 1;
  }
  return counts;
}

String? _sourceKind(JsonMap thread) {
  final direct = jsonString(thread['sourceKind']);
  if (direct != null) return direct;
  final source = thread['source'];
  if (source is String) return source;
  final sourceMap = jsonMap(source);
  return jsonString(sourceMap['kind']) ??
      jsonString(sourceMap['type']) ??
      jsonString(sourceMap['sourceKind']);
}

Map<String, int> _countBooleans(List<JsonMap> threads, String field) {
  final counts = <String, int>{'true': 0, 'false': 0, 'missingOrInvalid': 0};
  for (final thread in threads) {
    final value = thread[field];
    final key = value == true
        ? 'true'
        : value == false
        ? 'false'
        : 'missingOrInvalid';
    counts[key] = counts[key]! + 1;
  }
  return counts;
}

Map<String, int> _countCwds(List<JsonMap> threads, String fixtureCwd) {
  final counts = <String, int>{
    'exactMatch': 0,
    'different': 0,
    'missingOrInvalid': 0,
  };
  for (final thread in threads) {
    final cwd = jsonString(thread['cwd']);
    final key = cwd == null
        ? 'missingOrInvalid'
        : cwd == fixtureCwd
        ? 'exactMatch'
        : 'different';
    counts[key] = counts[key]! + 1;
  }
  return counts;
}

String _formatCounts(Map<String, int> counts) =>
    counts.entries.map((entry) => '${entry.key}:${entry.value}').join(',');
