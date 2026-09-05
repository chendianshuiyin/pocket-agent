import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

enum AuthenticationKind { password, privateKey }

class ProfileDraft {
  const ProfileDraft({
    this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authentication,
    required this.password,
    required this.privateKeyPem,
    required this.privateKeyPassphrase,
    required this.remoteCodexPort,
  });

  final String? id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthenticationKind authentication;
  final String password;
  final String privateKeyPem;
  final String privateKeyPassphrase;
  final int remoteCodexPort;
}

class ServerSummary {
  const ServerSummary({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authentication,
    required this.remoteCodexPort,
    required this.hasPinnedHostKey,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthenticationKind authentication;
  final int remoteCodexPort;
  final bool hasPinnedHostKey;
}

class HostKeyPrompt {
  const HostKeyPrompt({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
}

enum LinkPhase { disconnected, connecting, connected, failed }

class LinkSnapshot {
  const LinkSnapshot(this.phase, {this.message});
  final LinkPhase phase;
  final String? message;
}

abstract interface class ShellHandle {
  Stream<Uint8List> get output;
  void write(String data);
  void resize(int columns, int rows, {int pixelWidth = 0, int pixelHeight = 0});
  Future<void> close();
}

class TerminalSessionModel {
  TerminalSessionModel({
    required this.id,
    required this.title,
    required this.persistent,
    required this.handle,
  }) {
    terminal = Terminal(
      maxLines: 5000,
      onOutput: handle.write,
      onResize: (width, height, pixelWidth, pixelHeight) => handle.resize(
        width,
        height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ),
    );
    _outputSubscription = handle.output
        .map<List<int>>((bytes) => bytes)
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          terminal.write,
          onError: (Object _) =>
              terminal.write('\r\n\x1b[31m终端连接发生错误\x1b[0m\r\n'),
          onDone: () => terminal.write('\r\n\x1b[90m会话已结束\x1b[0m\r\n'),
        );
  }

  final String id;
  final String title;
  final bool persistent;
  final ShellHandle handle;
  late final Terminal terminal;
  late final StreamSubscription<String> _outputSubscription;

  Future<void> dispose() async {
    await _outputSubscription.cancel();
    await handle.close();
  }
}

enum ThreadRunState { idle, running, waitingApproval, error, completed }

enum RemoteAccountState { unknown, signedOut, authenticated }

class ThreadSummary {
  const ThreadSummary({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAt,
    required this.state,
  });
  final String id;
  final String title;
  final String preview;
  final DateTime? updatedAt;
  final ThreadRunState state;
}

enum TimelineKind { user, assistant, reasoning, tool, error, notice }

class TimelineItem {
  const TimelineItem({
    required this.id,
    required this.kind,
    required this.text,
    this.title,
    this.inProgress = false,
  });
  final String id;
  final TimelineKind kind;
  final String text;
  final String? title;
  final bool inProgress;
}

class SkillChoice {
  const SkillChoice({required this.name, required this.path, this.description});
  final String name;
  final String path;
  final String? description;
}

class ModelChoice {
  const ModelChoice({required this.id, required this.label, this.description});
  final String id;
  final String label;
  final String? description;
}

class UserInputQuestion {
  const UserInputQuestion({
    required this.id,
    required this.prompt,
    this.options = const [],
  });
  final String id;
  final String prompt;
  final List<String> options;
}

class UserInputPrompt {
  const UserInputPrompt({required this.questions, required this.raw});
  final List<UserInputQuestion> questions;
  final Object raw;
}

class ApprovalPrompt {
  const ApprovalPrompt({
    required this.id,
    required this.title,
    required this.details,
    required this.raw,
  });
  final String id;
  final String title;
  final String details;
  final Object raw;
}

class CodexWorkspaceSnapshot {
  const CodexWorkspaceSnapshot({
    this.connected = false,
    this.loading = false,
    this.error,
    this.threads = const [],
    this.loadingMoreThreads = false,
    this.nextThreadCursor,
    this.activeThreadId,
    this.timeline = const [],
    this.runState = ThreadRunState.idle,
    this.approval,
    this.userInput,
    this.skills = const [],
    this.models = const [],
    this.activeModel,
    this.accountState = RemoteAccountState.unknown,
    this.accountKind,
  });
  final bool connected;
  final bool loading;
  final String? error;
  final List<ThreadSummary> threads;
  final bool loadingMoreThreads;
  final String? nextThreadCursor;
  final String? activeThreadId;
  final List<TimelineItem> timeline;
  final ThreadRunState runState;
  final ApprovalPrompt? approval;
  final UserInputPrompt? userInput;
  final List<SkillChoice> skills;
  final List<ModelChoice> models;
  final String? activeModel;
  final RemoteAccountState accountState;
  final String? accountKind;

  CodexWorkspaceSnapshot copyWith({
    bool? connected,
    bool? loading,
    String? error,
    bool clearError = false,
    List<ThreadSummary>? threads,
    bool? loadingMoreThreads,
    String? nextThreadCursor,
    bool clearNextThreadCursor = false,
    String? activeThreadId,
    bool clearActiveThread = false,
    List<TimelineItem>? timeline,
    ThreadRunState? runState,
    ApprovalPrompt? approval,
    bool clearApproval = false,
    UserInputPrompt? userInput,
    bool clearUserInput = false,
    List<SkillChoice>? skills,
    List<ModelChoice>? models,
    String? activeModel,
    bool clearActiveModel = false,
    RemoteAccountState? accountState,
    String? accountKind,
  }) => CodexWorkspaceSnapshot(
    connected: connected ?? this.connected,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    threads: threads ?? this.threads,
    loadingMoreThreads: loadingMoreThreads ?? this.loadingMoreThreads,
    nextThreadCursor: clearNextThreadCursor
        ? null
        : nextThreadCursor ?? this.nextThreadCursor,
    activeThreadId: clearActiveThread
        ? null
        : activeThreadId ?? this.activeThreadId,
    timeline: timeline ?? this.timeline,
    runState: runState ?? this.runState,
    approval: clearApproval ? null : approval ?? this.approval,
    userInput: clearUserInput ? null : userInput ?? this.userInput,
    skills: skills ?? this.skills,
    models: models ?? this.models,
    activeModel: clearActiveModel ? null : activeModel ?? this.activeModel,
    accountState: accountState ?? this.accountState,
    accountKind: accountKind ?? this.accountKind,
  );
}
