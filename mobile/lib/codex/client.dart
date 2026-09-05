// ignore_for_file: curly_braces_in_flow_control_structures, prefer_initializing_formals, use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';

typedef WebSocketConnector = Future<WebSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

final class CodexClient {
  CodexClient._({
    required this.endpoint,
    required this.requestTimeout,
    required this.reconnectPolicy,
    required Map<String, String> headers,
    required WebSocketConnector connector,
  }) : _headers = Map<String, String>.unmodifiable(headers),
       _connector = connector;

  static Future<CodexClient> connect(
    Uri endpoint, {
    Duration requestTimeout = const Duration(seconds: 30),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    Map<String, String> headers = const <String, String>{},
    WebSocketConnector? socketConnector,
  }) async {
    _validateEndpoint(endpoint);
    final client = CodexClient._(
      endpoint: endpoint,
      requestTimeout: requestTimeout,
      reconnectPolicy: reconnectPolicy,
      headers: headers,
      connector: socketConnector ?? _defaultConnector,
    );
    try {
      await client._openAndInitialize(reconnecting: false);
      return client;
    } catch (_) {
      await client.dispose();
      rethrow;
    }
  }

  final Uri endpoint;
  final Duration requestTimeout;
  final ReconnectPolicy reconnectPolicy;
  final Map<String, String> _headers;
  final WebSocketConnector _connector;

  final _states = _ReplayBus<ConnectionSnapshot>(1);
  final _notifications = _ReplayBus<RpcNotification>(128);
  final _serverRequests = _ReplayBus<ServerRequest>(64);
  final _threadSnapshots = _ReplayBus<ThreadSnapshot>(8);
  final _turnSnapshots = _ReplayBus<TurnSnapshot>(64);
  final _itemSnapshots = _ReplayBus<ItemSnapshot>(32);
  final _protocolErrors = _ReplayBus<RpcException>(32);
  final Map<Object, _PendingRequest> _pending = <Object, _PendingRequest>{};
  final Map<Object, ServerRequest> _unresolvedServerRequests =
      <Object, ServerRequest>{};
  final Map<String, JsonMap> _items = <String, JsonMap>{};
  final Map<String, int> _itemRevisions = <String, int>{};

  WebSocket? _socket;
  StreamSubscription<Object?>? _socketSubscription;
  Timer? _reconnectTimer;
  Future<void>? _connectionFuture;
  var _generation = 0;
  var _nextRequestId = 0;
  var _hasConnected = false;
  var _disposed = false;
  String? _activeThreadId;
  ConnectionSnapshot _state = const ConnectionSnapshot(
    phase: ConnectionPhase.idle,
  );

  ConnectionSnapshot get state => _state;
  String? get activeThreadId => _activeThreadId;
  Stream<ConnectionSnapshot> get states => _states.stream;
  Stream<RpcNotification> get notifications => _notifications.stream;
  Stream<ServerRequest> get serverRequests => _serverRequests.stream;
  Stream<ThreadSnapshot> get threadSnapshots => _threadSnapshots.stream;
  Stream<TurnSnapshot> get turnSnapshots => _turnSnapshots.stream;
  Stream<ItemSnapshot> get itemSnapshots => _itemSnapshots.stream;
  Stream<RpcException> get protocolErrors => _protocolErrors.stream;

  Future<Object?> request(
    String method,
    JsonMap params, {
    Duration? timeout,
    RpcCancellationToken? cancellationToken,
  }) {
    if (_disposed)
      return Future<Object?>.error(
        const RpcConnectionException('Client is disposed'),
      );
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      return Future<Object?>.error(
        const RpcConnectionException('WebSocket is not connected'),
      );
    }

    final id = ++_nextRequestId;
    if (cancellationToken?.isCancelled == true) {
      return Future<Object?>.error(RpcCancelledException(method, id));
    }

    final completer = Completer<Object?>();
    late final _PendingRequest pending;
    void cancel() {
      if (!identical(_pending.remove(id), pending)) return;
      pending.dispose();
      completer.completeError(RpcCancelledException(method, id));
    }

    final effectiveTimeout = timeout ?? requestTimeout;
    pending = _PendingRequest(
      method: method,
      completer: completer,
      timer: Timer(effectiveTimeout, () {
        if (!identical(_pending.remove(id), pending)) return;
        pending.dispose();
        completer.completeError(RpcTimeoutException(method, id));
      }),
      removeCancellationListener: cancellationToken?.listen(cancel),
    );
    _pending[id] = pending;
    try {
      socket.add(
        jsonEncode(<String, Object?>{
          'method': method,
          'id': id,
          'params': params,
        }),
      );
    } catch (error) {
      _pending.remove(id);
      pending.dispose();
      completer.completeError(RpcConnectionException(error.toString()));
    }
    return completer.future;
  }

  void notify(String method, [JsonMap? params]) {
    _send(<String, Object?>{
      'method': method,
      if (params != null) 'params': params,
    });
  }

  void respond(Object id, Object? result) {
    _send(<String, Object?>{'id': id, 'result': result});
    _removeServerRequest(id);
  }

  void respondError(Object id, int code, String message, {Object? data}) {
    _send(<String, Object?>{
      'id': id,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });
    _removeServerRequest(id);
  }

  Future<Page<ModelInfo>> listModels({
    String? cursor,
    int? limit = 100,
    bool includeHidden = false,
  }) async {
    final result = jsonMap(
      await request('model/list', <String, Object?>{
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        'includeHidden': includeHidden,
      }),
    );
    return Page<ModelInfo>(
      data: jsonList(result['data'])
          .map(ModelInfo.fromJson)
          .toList(growable: false),
      nextCursor: jsonString(result['nextCursor']),
    );
  }

  Future<AccountStatus> readAccount({bool refreshToken = false}) async {
    final result = await request('account/read', <String, Object?>{
      'refreshToken': refreshToken,
    });
    return AccountStatus.fromJson(result);
  }

  Future<Page<CodexThread>> listThreads({
    String? cursor,
    int? limit = 50,
    String? cwd,
    bool archived = false,
    String? searchTerm,
    String sortKey = 'updated_at',
    String sortDirection = 'desc',
  }) async {
    final result = jsonMap(
      await request('thread/list', <String, Object?>{
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        if (cwd != null) 'cwd': cwd,
        'archived': archived,
        if (searchTerm != null) 'searchTerm': searchTerm,
        'sortKey': sortKey,
        'sortDirection': sortDirection,
        'sourceKinds': <String>['appServer'],
      }),
    );
    return Page<CodexThread>(
      data: jsonList(result['data'])
          .map(CodexThread.fromJson)
          .toList(growable: false),
      nextCursor: jsonString(result['nextCursor']),
      backwardsCursor: jsonString(result['backwardsCursor']),
    );
  }

  Future<CodexThread> startThread({
    String? cwd,
    String? model,
    CodexApprovalPolicy? approvalPolicy,
    CodexSandboxMode? sandbox,
    bool ephemeral = false,
  }) async {
    final result = jsonMap(
      await request('thread/start', <String, Object?>{
        if (cwd != null) 'cwd': cwd,
        if (model != null) 'model': model,
        if (approvalPolicy != null) 'approvalPolicy': approvalPolicy.wireValue,
        if (sandbox != null) 'sandbox': sandbox.wireValue,
        'ephemeral': ephemeral,
      }),
    );
    final thread = CodexThread.fromJson(result['thread']);
    _activeThreadId = thread.id;
    _threadSnapshots.add(ThreadSnapshot(thread));
    return thread;
  }

  Future<CodexThread> readThread(
    String threadId, {
    bool includeTurns = true,
  }) async {
    final result = jsonMap(
      await request('thread/read', <String, Object?>{
        'threadId': threadId,
        'includeTurns': includeTurns,
      }),
    );
    final thread = CodexThread.fromJson(result['thread']);
    _threadSnapshots.add(ThreadSnapshot(thread));
    return thread;
  }

  Future<CodexThread> resumeThread(
    String threadId, {
    String? cwd,
    String? model,
    CodexApprovalPolicy? approvalPolicy,
    CodexSandboxMode? sandbox,
  }) async {
    final result = jsonMap(
      await request('thread/resume', <String, Object?>{
        'threadId': threadId,
        if (cwd != null) 'cwd': cwd,
        if (model != null) 'model': model,
        if (approvalPolicy != null) 'approvalPolicy': approvalPolicy.wireValue,
        if (sandbox != null) 'sandbox': sandbox.wireValue,
      }),
    );
    final thread = CodexThread.fromJson(result['thread']);
    _activeThreadId = thread.id;
    _threadSnapshots.add(ThreadSnapshot(thread));
    return thread;
  }

  Future<CodexThread> openThread(String threadId) async {
    final history = await readThread(threadId, includeTurns: true);
    await resumeThread(threadId);
    _threadSnapshots.add(ThreadSnapshot(history));
    return history;
  }

  Future<void> archiveThread(String threadId) async {
    await request('thread/archive', <String, Object?>{'threadId': threadId});
    if (_activeThreadId == threadId) _activeThreadId = null;
  }

  Future<CodexTurn> startTurn(
    String threadId,
    List<CodexInput> input, {
    String? cwd,
    String? model,
    String? effort,
    CodexApprovalPolicy? approvalPolicy,
    CodexSandboxPolicy? sandboxPolicy,
    String? clientUserMessageId,
  }) async {
    _activeThreadId = threadId;
    final result = jsonMap(
      await request('turn/start', <String, Object?>{
        'threadId': threadId,
        'input': input.map((item) => item.toJson()).toList(growable: false),
        if (cwd != null) 'cwd': cwd,
        if (model != null) 'model': model,
        if (effort != null) 'effort': effort,
        if (approvalPolicy != null) 'approvalPolicy': approvalPolicy.wireValue,
        if (sandboxPolicy != null) 'sandboxPolicy': sandboxPolicy.toJson(),
        if (clientUserMessageId != null)
          'clientUserMessageId': clientUserMessageId,
      }),
    );
    final turn = CodexTurn.fromJson(result['turn']);
    _turnSnapshots.add(
      TurnSnapshot(
        threadId: threadId,
        turn: turn,
        completed: turn.status != 'inProgress',
      ),
    );
    return turn;
  }

  Future<CodexTurn> sendMessage(
    String threadId,
    String text, {
    SkillMetadata? skill,
    String? cwd,
    String? model,
    String? effort,
    CodexApprovalPolicy? approvalPolicy,
    CodexSandboxPolicy? sandboxPolicy,
    String? clientUserMessageId,
  }) {
    final input = <CodexInput>[
      CodexInput.text(skill == null ? text : '\$${skill.name} $text'),
      if (skill != null) CodexInput.skill(name: skill.name, path: skill.path),
    ];
    return startTurn(
      threadId,
      input,
      cwd: cwd,
      model: model,
      effort: effort,
      approvalPolicy: approvalPolicy,
      sandboxPolicy: sandboxPolicy,
      clientUserMessageId: clientUserMessageId,
    );
  }

  Future<String> steerTurn(
    String threadId,
    String expectedTurnId,
    List<CodexInput> input, {
    String? clientUserMessageId,
  }) async {
    final result = jsonMap(
      await request('turn/steer', <String, Object?>{
        'threadId': threadId,
        'expectedTurnId': expectedTurnId,
        'input': input.map((item) => item.toJson()).toList(growable: false),
        if (clientUserMessageId != null)
          'clientUserMessageId': clientUserMessageId,
      }),
    );
    return jsonString(result['turnId']) ?? expectedTurnId;
  }

  Future<bool> interruptTurn(String threadId, String turnId) async {
    final generation = _generation;
    await request('turn/interrupt', <String, Object?>{
      'threadId': threadId,
      'turnId': turnId,
    });
    if (generation != _generation) return false;
    _clearServerRequestsForTurn(threadId, turnId);
    return true;
  }

  Future<List<SkillGroup>> listSkills({
    List<String>? cwds,
    bool forceReload = false,
  }) async {
    final result = jsonMap(
      await request('skills/list', <String, Object?>{
        if (cwds != null) 'cwds': cwds,
        'forceReload': forceReload,
      }),
    );
    return jsonList(result['data'])
        .map(SkillGroup.fromJson)
        .toList(growable: false);
  }

  Future<void> compactThread(String threadId) async {
    await request('thread/compact/start', <String, Object?>{
      'threadId': threadId,
    });
  }

  Future<ReviewResult> reviewUncommittedChanges(
    String threadId, {
    ReviewDelivery delivery = ReviewDelivery.inline,
  }) async {
    final result = jsonMap(
      await request('review/start', <String, Object?>{
        'threadId': threadId,
        'target': <String, Object?>{'type': 'uncommittedChanges'},
        'delivery': delivery.wireValue,
      }),
    );
    return ReviewResult(
      turn: CodexTurn.fromJson(result['turn']),
      reviewThreadId: jsonString(result['reviewThreadId']) ?? threadId,
    );
  }

  bool respondApproval(ServerRequest request, ApprovalDecision decision) {
    const methods = <String>{
      'item/commandExecution/requestApproval',
      'item/fileChange/requestApproval',
    };
    if (!methods.contains(request.method)) {
      throw ArgumentError.value(
        request.method,
        'request.method',
        'Not a command or file approval request',
      );
    }
    if (!_isCurrentServerRequest(request)) return false;
    respond(request.id, <String, Object?>{'decision': decision.wireValue});
    return true;
  }

  bool respondUserInput(
    ServerRequest request,
    Map<String, List<String>> answers,
  ) {
    if (request.method != 'item/tool/requestUserInput' &&
        request.method != 'tool/requestUserInput') {
      throw ArgumentError.value(
        request.method,
        'request.method',
        'Not a user-input request',
      );
    }
    if (!_isCurrentServerRequest(request)) return false;
    respond(request.id, <String, Object?>{
      'answers': answers.map(
        (questionId, values) =>
            MapEntry(questionId, <String, Object?>{'answers': values}),
      ),
    });
    return true;
  }

  bool respondPermissions(
    ServerRequest request,
    JsonMap permissions, {
    String scope = 'turn',
  }) {
    if (request.method != 'item/permissions/requestApproval') {
      throw ArgumentError.value(
        request.method,
        'request.method',
        'Not a permissions request',
      );
    }
    if (!_isCurrentServerRequest(request)) return false;
    respond(request.id, <String, Object?>{
      'permissions': permissions,
      'scope': scope,
    });
    return true;
  }

  bool rejectServerRequest(ServerRequest request, {String? message}) {
    if (!_isCurrentServerRequest(request)) return false;
    respondError(
      request.id,
      -32601,
      message ?? 'Unsupported server request: ${request.method}',
    );
    return true;
  }

  Future<void> reconnect() async {
    if (_disposed) throw const RpcConnectionException('Client is disposed');
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final oldSocket = _socket;
    _generation += 1;
    _socket = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await oldSocket?.close(4000, 'manual reconnect');
    _failPending(const RpcConnectionException('Connection replaced'));
    _clearServerRequests();
    await _openAndInitialize(reconnecting: true);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _generation += 1;
    final socket = _socket;
    _socket = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _failPending(const RpcConnectionException('Client disposed'));
    _clearServerRequests();
    await socket?.close(WebSocketStatus.normalClosure, 'client disposed');
    _setState(const ConnectionSnapshot(phase: ConnectionPhase.disposed));
    await Future.wait<void>(<Future<void>>[
      _states.close(),
      _notifications.close(),
      _serverRequests.close(),
      _threadSnapshots.close(),
      _turnSnapshots.close(),
      _itemSnapshots.close(),
      _protocolErrors.close(),
    ]);
  }

  Future<void> _openAndInitialize({required bool reconnecting}) {
    if (_connectionFuture != null) return _connectionFuture!;
    final future = _doOpenAndInitialize(reconnecting: reconnecting);
    _connectionFuture = future;
    return future.whenComplete(() {
      if (identical(_connectionFuture, future)) _connectionFuture = null;
    });
  }

  Future<void> _doOpenAndInitialize({required bool reconnecting}) async {
    if (_disposed) throw const RpcConnectionException('Client is disposed');
    final generation = ++_generation;
    _setState(
      ConnectionSnapshot(
        phase: reconnecting
            ? ConnectionPhase.reconnecting
            : ConnectionPhase.connecting,
        attempt: reconnecting ? max(1, _state.attempt) : 0,
        server: _state.server,
      ),
    );

    late final WebSocket socket;
    try {
      socket = await _connector(endpoint, _headers);
    } catch (error) {
      throw RpcConnectionException('WebSocket connection failed: $error');
    }
    if (_disposed || generation != _generation) {
      await socket.close(4000, 'superseded');
      throw const RpcConnectionException('Connection replaced');
    }

    _socket = socket;
    _socketSubscription = socket.listen(
      (data) => _handleFrame(data),
      onError: (Object error, StackTrace stackTrace) =>
          _handleSocketError(generation, error),
      onDone: () =>
          _handleSocketDone(generation, socket.closeCode, socket.closeReason),
      cancelOnError: false,
    );
    _setState(
      ConnectionSnapshot(
        phase: ConnectionPhase.initializing,
        attempt: _state.attempt,
        server: _state.server,
      ),
    );

    final result = jsonMap(
      await request('initialize', <String, Object?>{
        'clientInfo': <String, Object?>{
          'name': 'pocket-agent-mobile',
          'title': 'Pocket Agent Mobile',
          'version': '1.0.0',
        },
        'capabilities': <String, Object?>{
          'experimentalApi': false,
          'requestAttestation': false,
        },
      }),
    );
    if (generation != _generation || _socket != socket) {
      throw const RpcConnectionException(
        'Connection replaced during initialization',
      );
    }
    notify('initialized', const <String, Object?>{});
    _hasConnected = true;
    _setState(ConnectionSnapshot(phase: ConnectionPhase.ready, server: result));

    if (reconnecting && _activeThreadId != null) {
      try {
        await _restoreActiveThread(_activeThreadId!);
      } catch (error) {
        _emitProtocolError(
          RpcException('Failed to restore active thread: $error'),
        );
      }
    }
  }

  Future<void> _restoreActiveThread(String threadId) async {
    final readResult = jsonMap(
      await request('thread/read', <String, Object?>{
        'threadId': threadId,
        'includeTurns': true,
      }),
    );
    final history = CodexThread.fromJson(readResult['thread']);
    final resumeResult = jsonMap(
      await request('thread/resume', <String, Object?>{'threadId': threadId}),
    );
    final resumed = CodexThread.fromJson(resumeResult['thread']);
    final recovered = resumed.turns.isEmpty && history.turns.isNotEmpty
        ? CodexThread.fromJson(<String, Object?>{
            ...history.raw,
            ...resumed.raw,
            'turns': history.raw['turns'],
          })
        : resumed;
    _threadSnapshots.add(ThreadSnapshot(recovered, recovered: true));
  }

  void _handleFrame(Object? frame) {
    late final String text;
    if (frame is String) {
      text = frame;
    } else if (frame is List<int>) {
      text = utf8.decode(frame);
    } else {
      _emitProtocolError(
        RpcException('Unsupported WebSocket frame: ${frame.runtimeType}'),
      );
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      _emitProtocolError(RpcException('Invalid JSON frame: $error'));
      return;
    }
    final message = jsonMap(decoded);
    final id = message['id'];
    final method = jsonString(message['method']);
    if (id != null && method != null) {
      final request = ServerRequest(
        id: id,
        method: method,
        params: jsonMap(message['params']),
      );
      _unresolvedServerRequests[id] = request;
      _serverRequests.add(request);
      return;
    }
    if (id != null &&
        (message.containsKey('result') || message.containsKey('error'))) {
      _handleResponse(id, message);
      return;
    }
    if (method != null) {
      final notification = RpcNotification(method, jsonMap(message['params']));
      _handleNotification(notification);
      _notifications.add(notification);
      return;
    }
    _emitProtocolError(const RpcException('Unrecognized JSON-RPC message'));
  }

  void _handleResponse(Object id, JsonMap message) {
    final pending = _pending.remove(id);
    if (pending == null) {
      _emitProtocolError(
        RpcException('Response for unknown request id', requestId: id),
      );
      return;
    }
    pending.dispose();
    final error = message['error'];
    if (error != null) {
      final details = jsonMap(error);
      pending.completer.completeError(
        RpcException(
          jsonString(details['message']) ?? 'JSON-RPC request failed',
          code: jsonInt(details['code']),
          data: details['data'],
          method: pending.method,
          requestId: id,
        ),
      );
      return;
    }
    pending.completer.complete(message['result']);
  }

  void _handleNotification(RpcNotification notification) {
    final params = notification.params;
    if (notification.method == 'serverRequest/resolved') {
      final requestId = params['requestId'];
      if (requestId != null) _removeServerRequest(requestId);
    }
    if (notification.method == 'thread/started') {
      final thread = CodexThread.fromJson(params['thread']);
      if (thread.id.isNotEmpty) _threadSnapshots.add(ThreadSnapshot(thread));
    }
    if (notification.method == 'turn/started' ||
        notification.method == 'turn/completed') {
      final turn = CodexTurn.fromJson(params['turn']);
      final threadId = jsonString(params['threadId']) ?? _activeThreadId ?? '';
      if (turn.id.isNotEmpty) {
        if (notification.method == 'turn/completed') {
          _clearServerRequestsForTurn(threadId, turn.id);
        }
        _turnSnapshots.add(
          TurnSnapshot(
            threadId: threadId,
            turn: turn,
            completed: notification.method == 'turn/completed',
          ),
        );
      }
    }
    if (notification.method == 'thread/archived' &&
        jsonString(params['threadId']) == _activeThreadId) {
      _activeThreadId = null;
    }
    _ingestItemNotification(notification);
  }

  void _ingestItemNotification(RpcNotification notification) {
    if (!notification.method.startsWith('item/')) return;
    final params = notification.params;
    final threadId = jsonString(params['threadId']) ?? '';
    final turnId = jsonString(params['turnId']) ?? '';
    var itemId = jsonString(params['itemId']) ?? '';
    final lifecycleItem = jsonMap(params['item']);
    if (lifecycleItem.isNotEmpty)
      itemId = jsonString(lifecycleItem['id']) ?? itemId;
    if (turnId.isEmpty || itemId.isEmpty) return;
    final key = '$threadId\u0000$turnId\u0000$itemId';
    if (!_items.containsKey(key) && _items.length >= 128) {
      final oldestKey = _items.keys.first;
      _items.remove(oldestKey);
      _itemRevisions.remove(oldestKey);
    }
    final completed = notification.method == 'item/completed';
    JsonMap item;
    if (lifecycleItem.isNotEmpty) {
      item = _boundedItem(lifecycleItem);
    } else {
      item = _deepCopy(
        _items[key] ??
            <String, Object?>{
              'id': itemId,
              'type': _itemTypeForDelta(notification.method),
            },
      );
      _applyDelta(notification.method, params, item);
    }
    _items[key] = item;
    final revision = (_itemRevisions[key] ?? 0) + 1;
    _itemRevisions[key] = revision;
    _itemSnapshots.add(
      ItemSnapshot(
        threadId: threadId,
        turnId: turnId,
        itemId: itemId,
        item: CodexItem.fromJson(_boundedItem(item)),
        revision: revision,
        completed: completed,
      ),
    );
  }

  void _applyDelta(String method, JsonMap params, JsonMap item) {
    final delta = jsonString(params['delta']) ?? '';
    switch (method) {
      case 'item/agentMessage/delta':
        _appendString(item, 'text', delta);
      case 'item/plan/delta':
        _appendString(item, 'text', delta);
      case 'item/reasoning/summaryTextDelta':
        _appendIndexed(
          item,
          'summary',
          jsonInt(params['summaryIndex']) ?? 0,
          delta,
        );
      case 'item/reasoning/textDelta':
        _appendIndexed(
          item,
          'content',
          jsonInt(params['contentIndex']) ?? 0,
          delta,
        );
      case 'item/commandExecution/outputDelta':
        _appendString(item, 'aggregatedOutput', delta);
      case 'item/fileChange/outputDelta':
        _appendString(item, 'output', delta);
      case 'item/fileChange/patchUpdated':
        if (params['changes'] is List)
          item['changes'] = _boundedCopyValue(params['changes']);
      case 'item/mcpToolCall/progress':
        _appendString(
          item,
          'progress',
          delta.isNotEmpty ? delta : jsonString(params['message']) ?? '',
        );
    }
  }

  void _appendString(JsonMap item, String field, String delta) {
    final combined = '${jsonString(item[field]) ?? ''}$delta';
    if (combined.length <= _maximumStreamedFieldCharacters) {
      item[field] = combined;
      return;
    }
    item[field] = combined.substring(
      combined.length - _maximumStreamedFieldCharacters,
    );
    item['_streamTruncated'] = true;
  }

  void _appendIndexed(JsonMap item, String field, int index, String delta) {
    final values = jsonList(item[field]);
    while (values.length <= index) {
      values.add('');
    }
    final combined = '${jsonString(values[index]) ?? ''}$delta';
    values[index] = combined.length <= _maximumStreamedFieldCharacters
        ? combined
        : combined.substring(combined.length - _maximumStreamedFieldCharacters);
    if (combined.length > _maximumStreamedFieldCharacters) {
      item['_streamTruncated'] = true;
    }
    item[field] = values;
  }

  String _itemTypeForDelta(String method) {
    if (method.startsWith('item/agentMessage/')) return 'agentMessage';
    if (method.startsWith('item/reasoning/')) return 'reasoning';
    if (method.startsWith('item/commandExecution/')) return 'commandExecution';
    if (method.startsWith('item/fileChange/')) return 'fileChange';
    if (method.startsWith('item/mcpToolCall/')) return 'mcpToolCall';
    if (method.startsWith('item/plan/')) return 'plan';
    return 'unknown';
  }

  void _handleSocketError(int generation, Object error) {
    if (_disposed || generation != _generation) return;
    _setState(_state.copyWith(error: error.toString()));
  }

  void _handleSocketDone(int generation, int? code, String? reason) {
    if (_disposed || generation != _generation) return;
    _socket = null;
    _socketSubscription = null;
    _clearServerRequests();
    final detail = reason?.isNotEmpty == true
        ? reason!
        : 'WebSocket closed${code == null ? '' : ' ($code)'}';
    _failPending(RpcConnectionException(detail));
    _setState(
      ConnectionSnapshot(
        phase: ConnectionPhase.disconnected,
        attempt: _state.attempt,
        error: detail,
        server: _state.server,
      ),
    );
    if (_hasConnected) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !reconnectPolicy.enabled || _reconnectTimer != null)
      return;
    final attempt = _state.attempt + 1;
    if (reconnectPolicy.maxAttempts != null &&
        attempt > reconnectPolicy.maxAttempts!)
      return;
    final multiplier = pow(2, max(0, attempt - 1)).toDouble();
    final delayMs = min(
      reconnectPolicy.maxDelay.inMilliseconds,
      (reconnectPolicy.initialDelay.inMilliseconds * multiplier).round(),
    );
    _setState(
      ConnectionSnapshot(
        phase: ConnectionPhase.disconnected,
        attempt: attempt,
        error: _state.error,
        server: _state.server,
      ),
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      _reconnectTimer = null;
      try {
        await _openAndInitialize(reconnecting: true);
      } catch (error) {
        if (_disposed) return;
        _setState(
          ConnectionSnapshot(
            phase: ConnectionPhase.disconnected,
            attempt: attempt,
            error: error.toString(),
            server: _state.server,
          ),
        );
        _scheduleReconnect();
      }
    });
  }

  void _send(JsonMap payload) {
    if (_disposed) throw const RpcConnectionException('Client is disposed');
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const RpcConnectionException('WebSocket is not connected');
    }
    socket.add(jsonEncode(payload));
  }

  void _failPending(RpcConnectionException error) {
    final pending = List<_PendingRequest>.from(_pending.values);
    _pending.clear();
    for (final request in pending) {
      request.dispose();
      if (!request.completer.isCompleted)
        request.completer.completeError(error);
    }
  }

  void _removeServerRequest(Object id) {
    _unresolvedServerRequests.remove(id);
    _serverRequests.removeWhere((request) => request.id == id);
  }

  bool _isCurrentServerRequest(ServerRequest request) =>
      identical(_unresolvedServerRequests[request.id], request);

  void _clearServerRequestsForTurn(String threadId, String turnId) {
    final ids = _unresolvedServerRequests.entries
        .where(
          (entry) =>
              entry.value.threadId == threadId && entry.value.turnId == turnId,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in ids) {
      _removeServerRequest(id);
    }
  }

  void _clearServerRequests() {
    _unresolvedServerRequests.clear();
    _serverRequests.clearHistory();
  }

  void _setState(ConnectionSnapshot state) {
    _state = state;
    _states.add(state);
  }

  void _emitProtocolError(RpcException error) => _protocolErrors.add(error);

  static Future<WebSocket> _defaultConnector(
    Uri uri,
    Map<String, String> headers,
  ) {
    return WebSocket.connect(uri.toString(), headers: headers);
  }

  static void _validateEndpoint(Uri endpoint) {
    if (endpoint.scheme != 'ws' && endpoint.scheme != 'wss') {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Only ws:// and wss:// endpoints are supported',
      );
    }
    final host = endpoint.host.toLowerCase();
    if (host != 'localhost' && host != '127.0.0.1' && host != '::1') {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'The app-server endpoint must be a loopback tunnel',
      );
    }
  }

  static JsonMap _deepCopy(JsonMap value) => jsonMap(_deepCopyValue(value));

  static const _maximumStreamedFieldCharacters = 256 * 1024;

  static JsonMap _boundedItem(JsonMap value) =>
      jsonMap(_boundedCopyValue(value));

  static Object? _boundedCopyValue(Object? value) {
    if (value is String && value.length > _maximumStreamedFieldCharacters) {
      return value.substring(value.length - _maximumStreamedFieldCharacters);
    }
    if (value is Map) {
      return Map<String, Object?>.fromEntries(
        value.entries
            .take(256)
            .map(
              (entry) => MapEntry(
                entry.key.toString(),
                _boundedCopyValue(entry.value),
              ),
            ),
      );
    }
    if (value is List) {
      return value.take(256).map(_boundedCopyValue).toList(growable: true);
    }
    return value;
  }

  static Object? _deepCopyValue(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>(
        (key, item) => MapEntry(key.toString(), _deepCopyValue(item)),
      );
    }
    if (value is List) return value.map(_deepCopyValue).toList(growable: true);
    return value;
  }
}

final class _PendingRequest {
  _PendingRequest({
    required this.method,
    required this.completer,
    required this.timer,
    required this.removeCancellationListener,
  });

  final String method;
  final Completer<Object?> completer;
  final Timer? timer;
  final void Function()? removeCancellationListener;

  void dispose() {
    timer?.cancel();
    removeCancellationListener?.call();
  }
}

final class _ReplayBus<T> {
  _ReplayBus(this.maximumHistory) {
    stream = Stream<T>.multi((controller) {
      for (final event in _history) {
        controller.addSync(event);
      }
      if (_closed) {
        controller.closeSync();
        return;
      }
      _listeners.add(controller);
      controller.onCancel = () => _listeners.remove(controller);
    }, isBroadcast: true);
  }

  final int maximumHistory;
  final List<T> _history = <T>[];
  final Set<MultiStreamController<T>> _listeners = <MultiStreamController<T>>{};
  late final Stream<T> stream;
  bool _closed = false;

  void add(T event) {
    if (_closed) return;
    if (maximumHistory > 0) {
      _history.add(event);
      if (_history.length > maximumHistory) _history.removeAt(0);
    }
    for (final listener in List<MultiStreamController<T>>.from(_listeners)) {
      listener.addSync(event);
    }
  }

  void removeWhere(bool Function(T event) predicate) =>
      _history.removeWhere(predicate);

  void clearHistory() => _history.clear();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final listener in List<MultiStreamController<T>>.from(_listeners)) {
      listener.closeSync();
    }
    _listeners.clear();
  }
}
