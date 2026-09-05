import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:pocket_agent/app/app_controller.dart';
import 'package:pocket_agent/app/app_models.dart';
import 'package:pocket_agent/app/app_services.dart';
import 'package:pocket_agent/ui/server_workspace_screen.dart';
import 'package:pocket_agent/ui/theme/pocket_theme.dart';

// Retaining this handle keeps accessibility semantics enabled for the process.
// ignore: unused_element
late final SemanticsHandle _previewSemantics;

const _sceneKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep Android accessibility nodes available throughout visual evaluation.
  _previewSemantics = SemanticsBinding.instance.ensureSemantics();
  runApp(const WorkspacePreviewApp());
}

class WorkspacePreviewApp extends StatelessWidget {
  const WorkspacePreviewApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '设计预览 · 模拟数据',
    theme: PocketTheme.light(),
    darkTheme: PocketTheme.dark(),
    themeMode: ThemeMode.system,
    home: const _PreviewHost(),
  );
}

enum _PreviewScene {
  ssh('SSH 终端', Icons.terminal_rounded),
  tasks('任务列表', Icons.view_list_rounded),
  conversation('对话与工具', Icons.forum_rounded),
  approval('待审批', Icons.policy_outlined),
  userInput('待用户输入', Icons.question_answer_outlined),
  offline('断线 / 错误', Icons.cloud_off_rounded);

  const _PreviewScene(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _SwitchSceneIntent extends Intent {
  const _SwitchSceneIntent(this.scene);
  final _PreviewScene scene;
}

class _PreviewHost extends StatefulWidget {
  const _PreviewHost();

  @override
  State<_PreviewHost> createState() => _PreviewHostState();
}

class _PreviewHostState extends State<_PreviewHost> {
  _PreviewScene _scene = _PreviewScene.ssh;
  ServerWorkspace? _workspace;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(_scene));
  }

  Future<void> _load(_PreviewScene scene) async {
    final generation = ++_loadGeneration;
    final previous = _workspace;
    setState(() {
      _scene = scene;
      _workspace = null;
    });
    // ServerWorkspace.dispose owns asynchronous teardown; preview switching must
    // not block its next deterministic scene on terminal stream completion.
    previous?.dispose();

    final services = _PreviewServices(scene);
    final workspace = ServerWorkspace(
      server: services.server,
      services: services,
    );
    final connected = await workspace.connect((_) async => true);
    if (connected && scene == _PreviewScene.ssh) {
      await workspace.openTerminal();
      await workspace.openTerminal(persistent: true, id: 'preview-build');
      await workspace.attachPersistentShell('preview-logs');
    } else if (connected && scene != _PreviewScene.offline) {
      workspace.selectFeature(1);
      await workspace.openCodex();
    }
    if (!mounted || generation != _loadGeneration) {
      await workspace.shutdown();
      workspace.dispose();
      return;
    }
    setState(() => _workspace = workspace);
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    final workspace = _workspace;
    _workspace = null;
    workspace?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      for (var i = 0; i < _PreviewScene.values.length; i++)
        SingleActivator(_sceneKeys[i], control: true): _SwitchSceneIntent(
          _PreviewScene.values[i],
        ),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {
          _SwitchSceneIntent: CallbackAction<_SwitchSceneIntent>(
            onInvoke: (intent) {
              unawaited(_load(intent.scene));
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                _PreviewBar(
                  scene: _scene,
                  onChanged: (scene) => unawaited(_load(scene)),
                ),
                Expanded(
                  child: _workspace == null
                      ? const Center(child: CircularProgressIndicator())
                      : ServerWorkspaceScreen(
                          key: ValueKey(_workspace),
                          workspace: _workspace!,
                          onBack: () => unawaited(_load(_PreviewScene.ssh)),
                          confirmHostKey: (_) async => true,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBar extends StatelessWidget {
  const _PreviewBar({required this.scene, required this.onChanged});
  final _PreviewScene scene;
  final ValueChanged<_PreviewScene> onChanged;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 390 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.25;
          final marker = const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_outlined, size: 18),
              SizedBox(width: PocketSpacing.xs),
              Flexible(
                child: Text(
                  '设计预览 · 模拟数据',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ],
          );
          final picker = DropdownButtonHideUnderline(
            child: DropdownButton<_PreviewScene>(
              key: const ValueKey('preview-scene-picker'),
              value: scene,
              isExpanded: stacked,
              borderRadius: BorderRadius.circular(PocketRadii.sm),
              icon: const Icon(Icons.expand_more_rounded),
              onChanged: (value) {
                if (value != null && value != scene) onChanged(value);
              },
              items: [
                for (final value in _PreviewScene.values)
                  DropdownMenuItem(
                    value: value,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(value.icon, size: 17),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            value.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PocketSpacing.sm,
                vertical: PocketSpacing.xxs,
              ),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [marker, picker],
                    )
                  : Row(
                      children: [
                        Expanded(child: marker),
                        const SizedBox(width: PocketSpacing.sm),
                        picker,
                      ],
                    ),
            ),
          );
        },
      ),
    ),
  );
}

class _PreviewServices implements AppServices {
  _PreviewServices(this.scene)
    : server = const ServerSummary(
        id: 'design-preview-server',
        name: '预览服务器 · 模拟',
        host: 'preview.invalid',
        port: 22,
        username: 'preview',
        authentication: AuthenticationKind.privateKey,
        remoteCodexPort: 4500,
        hasPinnedHostKey: true,
      );

  final _PreviewScene scene;
  final ServerSummary server;

  @override
  Future<List<ServerSummary>> listServers() async => [server];

  @override
  Future<ProfileDraft> loadServerDraft(String id) async => const ProfileDraft(
    id: 'design-preview-server',
    name: '预览服务器 · 模拟',
    host: 'preview.invalid',
    port: 22,
    username: 'preview',
    authentication: AuthenticationKind.privateKey,
    password: '',
    privateKeyPem: 'PREVIEW DATA ONLY',
    privateKeyPassphrase: '',
    remoteCodexPort: 4500,
  );

  @override
  Future<ServerSummary> saveServer(ProfileDraft draft) async => server;

  @override
  Future<void> deleteServer(String id) async {}

  @override
  Future<ConnectedServer> connectServer(
    String id, {
    required Future<bool> Function(HostKeyPrompt prompt) confirmHostKey,
  }) async {
    if (scene == _PreviewScene.offline) {
      throw StateError('Intentional local preview failure');
    }
    return _PreviewConnection(_PreviewCodexPort(scene));
  }
}

class _PreviewConnection implements ConnectedServer {
  _PreviewConnection(this._codex);
  final _PreviewCodexPort _codex;
  final _links = StreamController<LinkSnapshot>.broadcast();
  bool _connected = true;
  int _shellCount = 0;

  @override
  bool get isConnected => _connected;
  @override
  Stream<LinkSnapshot> get linkStates => _links.stream;

  @override
  Future<ShellHandle> openShell() async => _PreviewShellHandle(++_shellCount);
  @override
  Future<ShellHandle> createPersistentShell(String id) async =>
      _PreviewShellHandle(++_shellCount, label: id);
  @override
  Future<List<String>> listPersistentShells() async => const [
    'preview-build',
    'preview-logs',
  ];
  @override
  Future<ShellHandle> attachPersistentShell(String id) async =>
      _PreviewShellHandle(++_shellCount, label: id);
  @override
  Future<void> deletePersistentShell(String id) async {}
  @override
  Future<CodexPort> openCodex() async => _codex;

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    await _links.close();
  }
}

class _PreviewShellHandle implements ShellHandle {
  _PreviewShellHandle(this.index, {this.label = 'interactive'}) {
    final content = switch (index) {
      1 =>
        '\x1b[2J\x1b[H\x1b[36;1mPOCKET PREVIEW / LOCAL SIMULATION\x1b[0m\r\n'
            '\x1b[90m\$ preview status\x1b[0m\r\n'
            '工作区：\x1b[32m已就绪\x1b[0m  分支：codex/preview\r\n'
            '提示：下方快捷键仅写入本地模拟 shell\r\n\r\n'
            '\x1b[35mpreview@local\x1b[0m:\x1b[34m~/codex-pocket\x1b[0m\$ ',
      2 =>
        '\x1b[33;1m[模拟持久会话: $label]\x1b[0m\r\n'
            '[12:04:21] flutter analyze  \x1b[32m通过\x1b[0m\r\n'
            '[12:04:28] widget smoke test \x1b[32m通过\x1b[0m\r\n',
      _ =>
        '\x1b[34;1m[模拟日志: $label]\x1b[0m\r\n'
            'INFO  预览数据已加载\r\n'
            'WARN  未发起任何网络请求\r\n',
    };
    _output.add(Uint8List.fromList(utf8.encode(content)));
  }

  final int index;
  final String label;
  final _output = StreamController<Uint8List>();
  bool _closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;
  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}
  @override
  void write(String data) {
    if (!_closed) _output.add(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // A terminal cancels its subscription before closing the handle, so do not
    // wait on a single-subscription controller with no remaining listener.
    unawaited(_output.close());
  }
}

class _PreviewCodexPort implements CodexPort, CodexNavigationPort {
  _PreviewCodexPort(this.scene) : _current = _snapshotFor(scene);

  final _PreviewScene scene;
  final _snapshots = StreamController<CodexWorkspaceSnapshot>.broadcast();
  CodexWorkspaceSnapshot _current;

  @override
  CodexWorkspaceSnapshot get current => _current;
  @override
  Stream<CodexWorkspaceSnapshot> get snapshots => _snapshots.stream;

  void _emit(CodexWorkspaceSnapshot value) {
    _current = value;
    if (!_snapshots.isClosed) _snapshots.add(value);
  }

  @override
  Future<void> refreshThreads() async => _emit(_current);
  @override
  Future<void> loadMoreThreads() async => _emit(
    _current.copyWith(nextThreadCursor: null, clearNextThreadCursor: true),
  );
  @override
  Future<void> archiveThread(String id) async => _emit(
    _current.copyWith(
      threads: _current.threads.where((thread) => thread.id != id).toList(),
    ),
  );
  @override
  Future<void> createThread({String? cwd}) async => _emit(
    _conversationSnapshot().copyWith(
      timeline: [
        TimelineItem(
          id: 'created',
          kind: TimelineKind.notice,
          text: '已在本地预览中创建模拟任务${cwd == null ? '' : '：$cwd'}',
        ),
      ],
    ),
  );
  @override
  Future<void> openThread(String id) async => _emit(_conversationSnapshot());
  @override
  void showThreadList() => _emit(_baseSnapshot());
  @override
  Future<void> send(String text, {SkillChoice? skill}) async => _emit(
    _current.copyWith(
      timeline: [
        ..._current.timeline,
        TimelineItem(id: 'local-user', kind: TimelineKind.user, text: text),
        TimelineItem(
          id: 'local-notice',
          kind: TimelineKind.notice,
          text: '预览响应：未发送到模型${skill == null ? '' : '，已标记技能 ${skill.name}'}。',
        ),
      ],
      runState: ThreadRunState.completed,
    ),
  );
  @override
  Future<void> runCommand(String command) async => _emit(
    _current.copyWith(
      timeline: [
        ..._current.timeline,
        TimelineItem(
          id: 'command-$command',
          kind: TimelineKind.notice,
          text: '本地预览已选择 $command，未实际执行。',
        ),
      ],
    ),
  );
  @override
  Future<void> selectModel(String model) async =>
      _emit(_current.copyWith(activeModel: model));
  @override
  Future<void> interrupt() async =>
      _emit(_current.copyWith(runState: ThreadRunState.idle));
  @override
  Future<void> decideApproval(
    ApprovalPrompt prompt, {
    required bool approved,
  }) async => _emit(
    _current.copyWith(
      clearApproval: true,
      runState: ThreadRunState.completed,
      timeline: [
        ..._current.timeline,
        TimelineItem(
          id: 'approval-result',
          kind: TimelineKind.notice,
          text: '本地预览已记录：${approved ? '允许一次' : '拒绝'}（未执行命令）。',
        ),
      ],
    ),
  );
  @override
  Future<void> answerUserInput(
    UserInputPrompt prompt,
    Map<String, List<String>> answers,
  ) async => _emit(
    _current.copyWith(
      clearUserInput: true,
      runState: ThreadRunState.completed,
      timeline: [
        ..._current.timeline,
        const TimelineItem(
          id: 'answer-result',
          kind: TimelineKind.notice,
          text: '本地预览已记录回答，未发送到服务器。',
        ),
      ],
    ),
  );
  @override
  Future<void> dispose() async => _snapshots.close();

  static CodexWorkspaceSnapshot _snapshotFor(_PreviewScene scene) =>
      switch (scene) {
        _PreviewScene.tasks => _baseSnapshot(),
        _PreviewScene.approval => _conversationSnapshot().copyWith(
          runState: ThreadRunState.waitingApproval,
          approval: const ApprovalPrompt(
            id: 'preview-approval',
            title: '允许执行命令？',
            details: 'flutter test test/ui/terminal_pane_test.dart',
            raw: 'preview-only',
          ),
        ),
        _PreviewScene.userInput => _conversationSnapshot().copyWith(
          runState: ThreadRunState.waitingApproval,
          userInput: const UserInputPrompt(
            raw: 'preview-only',
            questions: [
              UserInputQuestion(
                id: 'platform',
                prompt: '这次评审优先哪个尺寸？',
                options: ['360 × 800', '412 × 915', '平板'],
              ),
              UserInputQuestion(id: 'notes', prompt: '还有什么需要关注？'),
            ],
          ),
        ),
        _ => _conversationSnapshot(),
      };

  static CodexWorkspaceSnapshot _baseSnapshot() => CodexWorkspaceSnapshot(
    connected: true,
    accountState: RemoteAccountState.authenticated,
    accountKind: 'preview',
    threads: [
      ThreadSummary(
        id: 'preview-active',
        title: '打磨移动端工作区',
        preview: '检查终端、任务列表与对话状态',
        updatedAt: DateTime(2026, 5, 9, 12, 4),
        state: ThreadRunState.completed,
      ),
      ThreadSummary(
        id: 'preview-running',
        title: '运行响应式布局检查',
        preview: '本地模拟任务运行中…',
        updatedAt: DateTime(2026, 5, 9, 11, 48),
        state: ThreadRunState.running,
      ),
      ThreadSummary(
        id: 'preview-error',
        title: '调查连接恢复',
        preview: '已保留一条模拟错误用于评审',
        updatedAt: DateTime(2026, 5, 8, 19, 20),
        state: ThreadRunState.error,
      ),
    ],
    nextThreadCursor: 'preview-next-page',
    skills: const [
      SkillChoice(
        name: 'design-polish',
        path: '/preview/design-polish',
        description: '模拟技能：检查视觉层级与间距',
      ),
      SkillChoice(
        name: 'responsive-layout',
        path: '/preview/responsive-layout',
        description: '模拟技能：验证多尺寸布局',
      ),
    ],
    models: const [
      ModelChoice(id: 'preview-balanced', label: '预览模型 · 平衡'),
      ModelChoice(id: 'preview-fast', label: '预览模型 · 快速'),
    ],
    activeModel: 'preview-balanced',
  );

  static CodexWorkspaceSnapshot _conversationSnapshot() =>
      _baseSnapshot().copyWith(
        activeThreadId: 'preview-active',
        runState: ThreadRunState.completed,
        timeline: const [
          TimelineItem(
            id: 'user-1',
            kind: TimelineKind.user,
            text: '请检查手机端工作区的视觉层级。',
          ),
          TimelineItem(
            id: 'reasoning-1',
            kind: TimelineKind.reasoning,
            title: '分析布局',
            text: '正在检查导航、对话密度和操作可见性。',
          ),
          TimelineItem(
            id: 'tool-1',
            kind: TimelineKind.tool,
            title: '读取文件 · 模拟工具输出',
            text:
                'lib/ui/server_workspace_screen.dart\n'
                'lib/ui/codex_pane.dart\n'
                '本预览没有访问文件系统或网络。',
          ),
          TimelineItem(
            id: 'assistant-1',
            kind: TimelineKind.assistant,
            text: '页面的主层级清晰；下一步可聚焦审批卡片和输入区的对比度。',
          ),
        ],
      );
}
