typedef JsonMap = Map<String, Object?>;

JsonMap jsonMap(Object? value) {
  if (value is! Map) return <String, Object?>{};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Object?> jsonList(Object? value) =>
    value is List ? List<Object?>.from(value) : const <Object?>[];

String? jsonString(Object? value) => value is String ? value : null;
int? jsonInt(Object? value) => value is int
    ? value
    : value is num
    ? value.toInt()
    : null;

enum ConnectionPhase {
  idle,
  connecting,
  initializing,
  ready,
  reconnecting,
  disconnected,
  disposed,
}

final class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.phase,
    this.attempt = 0,
    this.error,
    this.server,
  });

  final ConnectionPhase phase;
  final int attempt;
  final String? error;
  final JsonMap? server;

  ConnectionSnapshot copyWith({
    ConnectionPhase? phase,
    int? attempt,
    String? error,
    bool clearError = false,
    JsonMap? server,
  }) => ConnectionSnapshot(
    phase: phase ?? this.phase,
    attempt: attempt ?? this.attempt,
    error: clearError ? null : error ?? this.error,
    server: server ?? this.server,
  );
}

final class RpcNotification {
  const RpcNotification(this.method, this.params);

  final String method;
  final JsonMap params;
}

final class ServerRequest {
  const ServerRequest({
    required this.id,
    required this.method,
    required this.params,
  });

  final Object id;
  final String method;
  final JsonMap params;

  String? get threadId => jsonString(params['threadId']);
  String? get turnId => jsonString(params['turnId']);
  String? get itemId => jsonString(params['itemId']);
  bool? get isBlocking =>
      params['isBlocking'] is bool ? params['isBlocking']! as bool : null;
  int? get autoResolutionMs => jsonInt(params['autoResolutionMs']);
  List<CodexUserInputQuestion> get questions =>
      jsonList(params['questions'])
          .map(CodexUserInputQuestion.fromJson)
          .toList(growable: false);
}

final class CodexUserInputOption {
  const CodexUserInputOption({required this.label, required this.description});

  factory CodexUserInputOption.fromJson(Object? value) {
    final raw = jsonMap(value);
    return CodexUserInputOption(
      label: jsonString(raw['label']) ?? '',
      description: jsonString(raw['description']) ?? '',
    );
  }

  final String label;
  final String description;
}

final class CodexUserInputQuestion {
  const CodexUserInputQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.isOther,
    required this.isSecret,
    required this.options,
  });

  factory CodexUserInputQuestion.fromJson(Object? value) {
    final raw = jsonMap(value);
    return CodexUserInputQuestion(
      id: jsonString(raw['id']) ?? '',
      header: jsonString(raw['header']) ?? '',
      question: jsonString(raw['question']) ?? '',
      isOther: raw['isOther'] == true,
      isSecret: raw['isSecret'] == true,
      options: jsonList(raw['options'])
          .map(CodexUserInputOption.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String header;
  final String question;
  final bool isOther;
  final bool isSecret;
  final List<CodexUserInputOption> options;
}

class RpcException implements Exception {
  const RpcException(
    this.message, {
    this.code,
    this.data,
    this.method,
    this.requestId,
  });

  final String message;
  final int? code;
  final Object? data;
  final String? method;
  final Object? requestId;

  @override
  String toString() =>
      code == null ? 'RpcException: $message' : 'RpcException($code): $message';
}

final class RpcTimeoutException extends RpcException {
  const RpcTimeoutException(String method, Object requestId)
    : super('Request timed out', method: method, requestId: requestId);
}

final class RpcCancelledException extends RpcException {
  const RpcCancelledException(String method, Object requestId)
    : super('Request cancelled', method: method, requestId: requestId);
}

final class RpcConnectionException extends RpcException {
  const RpcConnectionException(super.message);
}

final class RpcCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

final class Page<T> {
  const Page({required this.data, this.nextCursor, this.backwardsCursor});

  final List<T> data;
  final String? nextCursor;
  final String? backwardsCursor;
}

enum AccountKind { signedOut, apiKey, chatgpt, amazonBedrock, unknown }

final class AccountStatus {
  const AccountStatus({
    required this.isAuthenticated,
    required this.requiresOpenaiAuth,
    required this.kind,
  });

  factory AccountStatus.fromJson(Object? value) {
    final response = jsonMap(value);
    final account = jsonMap(response['account']);
    final type = jsonString(account['type']);
    final kind = switch (type) {
      null => AccountKind.signedOut,
      'apiKey' => AccountKind.apiKey,
      'chatgpt' => AccountKind.chatgpt,
      'amazonBedrock' => AccountKind.amazonBedrock,
      _ => AccountKind.unknown,
    };
    return AccountStatus(
      isAuthenticated: response['account'] != null,
      requiresOpenaiAuth: response['requiresOpenaiAuth'] == true,
      kind: kind,
    );
  }

  final bool isAuthenticated;
  final bool requiresOpenaiAuth;
  final AccountKind kind;
}

final class ThreadStatus {
  const ThreadStatus(this.type, this.activeFlags, this.raw);

  factory ThreadStatus.fromJson(Object? value) {
    final raw = jsonMap(value);
    return ThreadStatus(
      jsonString(raw['type']) ?? 'unknown',
      jsonList(raw['activeFlags']).whereType<String>().toList(growable: false),
      raw,
    );
  }

  final String type;
  final List<String> activeFlags;
  final JsonMap raw;
}

final class CodexItem {
  const CodexItem({required this.type, required this.id, required this.data});

  factory CodexItem.fromJson(Object? value) {
    final data = jsonMap(value);
    return CodexItem(
      type: jsonString(data['type']) ?? 'unknown',
      id: jsonString(data['id']),
      data: data,
    );
  }

  final String type;
  final String? id;
  final JsonMap data;
}

final class CodexTurn {
  const CodexTurn({
    required this.id,
    required this.status,
    required this.items,
    required this.error,
    required this.raw,
  });

  factory CodexTurn.fromJson(Object? value) {
    final raw = jsonMap(value);
    return CodexTurn(
      id: jsonString(raw['id']) ?? '',
      status: jsonString(raw['status']) ?? 'unknown',
      items: jsonList(raw['items'])
          .map(CodexItem.fromJson)
          .toList(growable: false),
      error: raw['error'],
      raw: raw,
    );
  }

  final String id;
  final String status;
  final List<CodexItem> items;
  final Object? error;
  final JsonMap raw;
}

final class CodexThread {
  const CodexThread({
    required this.id,
    required this.sessionId,
    required this.preview,
    required this.name,
    required this.cwd,
    required this.modelProvider,
    required this.createdAt,
    required this.updatedAt,
    required this.recencyAt,
    required this.status,
    required this.turns,
    required this.raw,
  });

  factory CodexThread.fromJson(Object? value) {
    final raw = jsonMap(value);
    return CodexThread(
      id: jsonString(raw['id']) ?? '',
      sessionId: jsonString(raw['sessionId']) ?? jsonString(raw['id']) ?? '',
      preview: jsonString(raw['preview']) ?? '',
      name: jsonString(raw['name']),
      cwd: jsonString(raw['cwd']) ?? '',
      modelProvider: jsonString(raw['modelProvider']) ?? '',
      createdAt: jsonInt(raw['createdAt']),
      updatedAt: jsonInt(raw['updatedAt']),
      recencyAt: jsonInt(raw['recencyAt']),
      status: ThreadStatus.fromJson(raw['status']),
      turns: jsonList(raw['turns'])
          .map(CodexTurn.fromJson)
          .toList(growable: false),
      raw: raw,
    );
  }

  final String id;
  final String sessionId;
  final String preview;
  final String? name;
  final String cwd;
  final String modelProvider;
  final int? createdAt;
  final int? updatedAt;
  final int? recencyAt;
  final ThreadStatus status;
  final List<CodexTurn> turns;
  final JsonMap raw;
}

final class ThreadSnapshot {
  const ThreadSnapshot(this.thread, {this.recovered = false});

  final CodexThread thread;
  final bool recovered;
}

final class TurnSnapshot {
  const TurnSnapshot({
    required this.threadId,
    required this.turn,
    required this.completed,
  });

  final String threadId;
  final CodexTurn turn;
  final bool completed;
}

final class ItemSnapshot {
  const ItemSnapshot({
    required this.threadId,
    required this.turnId,
    required this.itemId,
    required this.item,
    required this.revision,
    required this.completed,
  });

  final String threadId;
  final String turnId;
  final String itemId;
  final CodexItem item;
  final int revision;
  final bool completed;
}

final class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.model,
    required this.displayName,
    required this.description,
    required this.isDefault,
    required this.hidden,
    required this.supportedReasoningEfforts,
    required this.raw,
  });

  factory ModelInfo.fromJson(Object? value) {
    final raw = jsonMap(value);
    return ModelInfo(
      id: jsonString(raw['id']) ?? jsonString(raw['model']) ?? '',
      model: jsonString(raw['model']) ?? jsonString(raw['id']) ?? '',
      displayName:
          jsonString(raw['displayName']) ?? jsonString(raw['model']) ?? '',
      description: jsonString(raw['description']) ?? '',
      isDefault: raw['isDefault'] == true,
      hidden: raw['hidden'] == true,
      supportedReasoningEfforts: jsonList(raw['supportedReasoningEfforts'])
          .map(jsonMap)
          .toList(growable: false),
      raw: raw,
    );
  }

  final String id;
  final String model;
  final String displayName;
  final String description;
  final bool isDefault;
  final bool hidden;
  final List<JsonMap> supportedReasoningEfforts;
  final JsonMap raw;
}

final class SkillMetadata {
  const SkillMetadata({
    required this.name,
    required this.description,
    required this.path,
    required this.scope,
    required this.enabled,
    required this.raw,
  });

  factory SkillMetadata.fromJson(Object? value) {
    final raw = jsonMap(value);
    return SkillMetadata(
      name: jsonString(raw['name']) ?? '',
      description: jsonString(raw['description']) ?? '',
      path: jsonString(raw['path']) ?? '',
      scope: jsonString(raw['scope']) ?? 'unknown',
      enabled: raw['enabled'] != false,
      raw: raw,
    );
  }

  final String name;
  final String description;
  final String path;
  final String scope;
  final bool enabled;
  final JsonMap raw;
}

final class SkillError {
  const SkillError(this.path, this.message);

  factory SkillError.fromJson(Object? value) {
    final raw = jsonMap(value);
    return SkillError(
      jsonString(raw['path']) ?? '',
      jsonString(raw['message']) ?? '',
    );
  }

  final String path;
  final String message;
}

final class SkillGroup {
  const SkillGroup({
    required this.cwd,
    required this.skills,
    required this.errors,
  });

  factory SkillGroup.fromJson(Object? value) {
    final raw = jsonMap(value);
    return SkillGroup(
      cwd: jsonString(raw['cwd']) ?? '',
      skills: jsonList(raw['skills'])
          .map(SkillMetadata.fromJson)
          .toList(growable: false),
      errors: jsonList(raw['errors'])
          .map(SkillError.fromJson)
          .toList(growable: false),
    );
  }

  final String cwd;
  final List<SkillMetadata> skills;
  final List<SkillError> errors;
}

sealed class CodexInput {
  const CodexInput();

  const factory CodexInput.text(String text) = TextCodexInput;
  const factory CodexInput.skill({required String name, required String path}) =
      SkillCodexInput;

  JsonMap toJson();
}

final class TextCodexInput extends CodexInput {
  const TextCodexInput(this.text);

  final String text;

  @override
  JsonMap toJson() => <String, Object?>{
    'type': 'text',
    'text': text,
    'text_elements': <Object?>[],
  };
}

final class SkillCodexInput extends CodexInput {
  const SkillCodexInput({required this.name, required this.path});

  final String name;
  final String path;

  @override
  JsonMap toJson() => <String, Object?>{
    'type': 'skill',
    'name': name,
    'path': path,
  };
}

enum ApprovalDecision {
  accept('accept'),
  acceptForSession('acceptForSession'),
  decline('decline'),
  cancel('cancel');

  const ApprovalDecision(this.wireValue);
  final String wireValue;
}

enum CodexApprovalPolicy {
  untrusted('untrusted'),
  onRequest('on-request'),
  never('never');

  const CodexApprovalPolicy(this.wireValue);
  final String wireValue;
}

enum CodexSandboxMode {
  readOnly('read-only'),
  workspaceWrite('workspace-write'),
  dangerFullAccess('danger-full-access');

  const CodexSandboxMode(this.wireValue);
  final String wireValue;
}

sealed class CodexSandboxPolicy {
  const CodexSandboxPolicy();

  const factory CodexSandboxPolicy.readOnly({bool networkAccess}) =
      ReadOnlySandboxPolicy;
  const factory CodexSandboxPolicy.workspaceWrite({
    List<String> writableRoots,
    bool networkAccess,
    bool excludeTmpdirEnvVar,
    bool excludeSlashTmp,
  }) = WorkspaceWriteSandboxPolicy;
  const factory CodexSandboxPolicy.dangerFullAccess() =
      DangerFullAccessSandboxPolicy;

  JsonMap toJson();
}

final class ReadOnlySandboxPolicy extends CodexSandboxPolicy {
  const ReadOnlySandboxPolicy({this.networkAccess = false});

  final bool networkAccess;

  @override
  JsonMap toJson() => <String, Object?>{
    'type': 'readOnly',
    'networkAccess': networkAccess,
  };
}

final class WorkspaceWriteSandboxPolicy extends CodexSandboxPolicy {
  const WorkspaceWriteSandboxPolicy({
    this.writableRoots = const <String>[],
    this.networkAccess = false,
    this.excludeTmpdirEnvVar = false,
    this.excludeSlashTmp = false,
  });

  final List<String> writableRoots;
  final bool networkAccess;
  final bool excludeTmpdirEnvVar;
  final bool excludeSlashTmp;

  @override
  JsonMap toJson() => <String, Object?>{
    'type': 'workspaceWrite',
    'writableRoots': writableRoots,
    'networkAccess': networkAccess,
    'excludeTmpdirEnvVar': excludeTmpdirEnvVar,
    'excludeSlashTmp': excludeSlashTmp,
  };
}

final class DangerFullAccessSandboxPolicy extends CodexSandboxPolicy {
  const DangerFullAccessSandboxPolicy();

  @override
  JsonMap toJson() => <String, Object?>{'type': 'dangerFullAccess'};
}

enum ReviewDelivery {
  inline('inline'),
  detached('detached');

  const ReviewDelivery(this.wireValue);
  final String wireValue;
}

final class ReviewResult {
  const ReviewResult({required this.turn, required this.reviewThreadId});

  final CodexTurn turn;
  final String reviewThreadId;
}

final class ReconnectPolicy {
  const ReconnectPolicy({
    this.enabled = true,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 15),
    this.maxAttempts = 6,
  });

  final bool enabled;
  final Duration initialDelay;
  final Duration maxDelay;
  final int? maxAttempts;
}
