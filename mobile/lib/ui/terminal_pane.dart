import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app/app_controller.dart';
import 'theme/pocket_theme.dart';

class TerminalPane extends StatelessWidget {
  const TerminalPane({super.key, required this.workspace});
  final ServerWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    if (!workspace.connected) {
      return _TerminalEmpty(
        title: workspace.busy ? '正在建立安全连接…' : 'SSH 尚未连接',
        actionLabel: null,
        onAction: null,
      );
    }
    if (workspace.terminals.isEmpty) {
      return _EmptyTerminalActions(
        workspace: workspace,
        createPersistent: () => _createPersistentFromEmpty(context, workspace),
        attachPersistent: () => _attachPersistentFromEmpty(context, workspace),
      );
    }
    return Column(
      children: [
        _TerminalTabs(workspace: workspace),
        Expanded(
          child: IndexedStack(
            index: workspace.selectedTerminal,
            children: workspace.terminals
                .map(
                  (session) => ColoredBox(
                    color: PocketTheme.terminalBackground,
                    child: TerminalView(
                      session.terminal,
                      key: ValueKey('terminal-view-${session.id}'),
                      padding: const EdgeInsets.all(PocketSpacing.sm),
                      autofocus: true,
                      deleteDetection: true,
                      textStyle: const TerminalStyle(
                        fontSize: 13.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
        _QuickKeys(workspace: workspace),
      ],
    );
  }
}

class _EmptyTerminalActions extends StatelessWidget {
  const _EmptyTerminalActions({
    required this.workspace,
    required this.createPersistent,
    required this.attachPersistent,
  });
  final ServerWorkspace workspace;
  final VoidCallback createPersistent;
  final VoidCallback attachPersistent;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(PocketSpacing.lg),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(PocketRadii.md),
            ),
            child: Icon(
              Icons.terminal_rounded,
              size: 28,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: PocketSpacing.md),
          Text(
            '打开一个交互终端',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: PocketSpacing.xs),
          Text(
            '普通终端随连接结束；持久终端可稍后重新附加。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: PocketSpacing.lg),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: PocketSpacing.xs,
            runSpacing: PocketSpacing.xs,
            children: [
              FilledButton.icon(
                onPressed: workspace.busy ? null : workspace.openTerminal,
                icon: const Icon(Icons.add_rounded),
                label: const Text('普通终端'),
              ),
              OutlinedButton.icon(
                onPressed: workspace.busy ? null : createPersistent,
                icon: const Icon(Icons.push_pin_outlined),
                label: const Text('持久终端'),
              ),
              TextButton.icon(
                onPressed: workspace.busy ? null : attachPersistent,
                icon: const Icon(Icons.link_rounded),
                label: const Text('附加已有'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> _createPersistentFromEmpty(
  BuildContext context,
  ServerWorkspace workspace,
) async {
  var sessionId = 'main';
  final id = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('新建持久终端'),
      content: TextFormField(
        key: const ValueKey('persistent-terminal-id'),
        initialValue: sessionId,
        autofocus: true,
        autocorrect: false,
        onChanged: (value) => sessionId = value,
        decoration: const InputDecoration(
          labelText: '会话名称',
          helperText: '1–48 位，仅字母、数字、_、-',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = sessionId.trim();
            if (RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(value)) {
              Navigator.pop(context, value);
            }
          },
          child: const Text('创建'),
        ),
      ],
    ),
  );
  if (id != null) await workspace.openTerminal(persistent: true, id: id);
}

Future<void> _attachPersistentFromEmpty(
  BuildContext context,
  ServerWorkspace workspace,
) async {
  List<String> sessions;
  try {
    sessions = await workspace.listPersistentShells();
  } catch (_) {
    sessions = const [];
  }
  if (!context.mounted) return;
  if (sessions.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('没有可附加的持久终端。')));
    return;
  }
  final id = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: sessions.length,
        itemBuilder: (context, index) => ListTile(
          leading: const Icon(Icons.terminal_rounded),
          title: Text(sessions[index]),
          subtitle: const Text('远程 tmux 会话'),
          onTap: () => Navigator.pop(context, sessions[index]),
        ),
      ),
    ),
  );
  if (id != null) await workspace.attachPersistentShell(id);
}

class _TerminalTabs extends StatefulWidget {
  const _TerminalTabs({required this.workspace});
  final ServerWorkspace workspace;

  @override
  State<_TerminalTabs> createState() => _TerminalTabsState();
}

class _TerminalTabsState extends State<_TerminalTabs> {
  static const _tabWidth = 144.0;
  static const _tabSpacing = PocketSpacing.xs;
  final _scrollController = ScrollController();
  int _lastTerminalCount = -1;
  int _lastSelectedTerminal = -1;
  double _lastViewportWidth = -1;

  ServerWorkspace get workspace => widget.workspace;

  @override
  void didUpdateWidget(covariant _TerminalTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      _lastTerminalCount = -1;
      _lastSelectedTerminal = -1;
      _lastViewportWidth = -1;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _ensureSelectedVisible(double viewportWidth) {
    final count = workspace.terminals.length;
    final selected = workspace.selectedTerminal;
    if (count == _lastTerminalCount &&
        selected == _lastSelectedTerminal &&
        (viewportWidth - _lastViewportWidth).abs() < 0.5) {
      return;
    }
    _lastTerminalCount = count;
    _lastSelectedTerminal = selected;
    _lastViewportWidth = viewportWidth;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || count == 0) return;
      if (workspace.terminals.length != count ||
          workspace.selectedTerminal != selected) {
        return;
      }
      final position = _scrollController.position;
      final leading = PocketSpacing.xs + selected * (_tabWidth + _tabSpacing);
      final trailing = leading + _tabWidth;
      var target = position.pixels;
      if (leading < position.pixels) {
        target = leading;
      } else if (trailing > position.pixels + position.viewportDimension) {
        target = trailing - position.viewportDimension;
      }
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 0.5) return;
      if (disableAnimations) {
        _scrollController.jumpTo(target);
        return;
      }
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final chipHeight = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(17) + 16,
    );
    return SizedBox(
      height: chipHeight + PocketSpacing.md,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _ensureSelectedVisible(constraints.maxWidth);
                  return ListView.builder(
                    key: const ValueKey('terminal-tabs-scroll'),
                    controller: _scrollController,
                    itemExtent: _tabWidth + _tabSpacing,
                    padding: const EdgeInsets.symmetric(
                      horizontal: PocketSpacing.xs,
                      vertical: PocketSpacing.xs,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: workspace.terminals.length,
                    itemBuilder: (context, index) {
                      final terminal = workspace.terminals[index];
                      final selected = workspace.selectedTerminal == index;
                      return Padding(
                        padding: const EdgeInsets.only(right: _tabSpacing),
                        child: SizedBox(
                          key: ValueKey('terminal-tab-slot-${terminal.id}'),
                          width: _tabWidth,
                          height: chipHeight,
                          child: Tooltip(
                            message: terminal.title,
                            child: InputChip(
                              key: ValueKey('terminal-tab-${terminal.id}'),
                              selected: selected,
                              avatar: Icon(
                                terminal.persistent
                                    ? Icons.push_pin_outlined
                                    : Icons.terminal_rounded,
                                size: 16,
                              ),
                              label: Text(
                                terminal.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () {
                                workspace.selectTerminal(index);
                                setState(() {});
                              },
                              onDeleted: () => _close(context, index),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            IconButton(
              tooltip: '新建终端',
              onPressed: workspace.busy
                  ? null
                  : () async {
                      await workspace.openTerminal();
                      if (mounted) setState(() {});
                    },
              icon: const Icon(Icons.add_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: '持久终端',
              icon: const Icon(Icons.push_pin_outlined),
              onSelected: (value) => value == 'create'
                  ? _createPersistent(context)
                  : _attachPersistent(context),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'create',
                  child: ListTile(
                    leading: Icon(Icons.add_box_outlined),
                    title: Text('新建持久终端'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'attach',
                  child: ListTile(
                    leading: Icon(Icons.link_rounded),
                    title: Text('附加已有终端'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _close(BuildContext context, int index) async {
    final terminal = workspace.terminals[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(terminal.persistent ? '关闭本地视图？' : '关闭终端？'),
        content: Text(
          terminal.persistent ? '远程 tmux 会话会继续运行，可稍后重新附加。' : '当前 shell 进程将结束。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await workspace.closeTerminal(index);
      if (mounted) setState(() {});
    }
  }

  Future<void> _createPersistent(BuildContext context) async {
    var sessionId = 'main';
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建持久终端'),
        content: TextFormField(
          key: const ValueKey('persistent-terminal-id'),
          initialValue: sessionId,
          autofocus: true,
          autocorrect: false,
          onChanged: (value) => sessionId = value,
          decoration: const InputDecoration(
            labelText: '会话名称',
            helperText: '1–48 位，仅字母、数字、_、-',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = sessionId.trim();
              if (RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(value)) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (id != null) {
      await workspace.openTerminal(persistent: true, id: id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _attachPersistent(BuildContext context) async {
    List<String> sessions;
    try {
      sessions = await workspace.listPersistentShells();
    } catch (_) {
      sessions = const [];
    }
    if (!context.mounted) return;
    if (sessions.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可附加的持久终端。')));
      return;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: sessions.length,
          itemBuilder: (context, index) => ListTile(
            leading: const Icon(Icons.terminal_rounded),
            title: Text(sessions[index]),
            subtitle: const Text('远程 tmux 会话'),
            onTap: () => Navigator.pop(context, sessions[index]),
          ),
        ),
      ),
    );
    if (id != null) {
      await workspace.attachPersistentShell(id);
      if (mounted) setState(() {});
    }
  }
}

class _QuickKeys extends StatelessWidget {
  const _QuickKeys({required this.workspace});
  final ServerWorkspace workspace;
  @override
  Widget build(BuildContext context) {
    final terminal = workspace.terminals[workspace.selectedTerminal].terminal;
    final keys = <(String, String)>[
      ('Esc', '\x1b'),
      ('Ctrl+C', '\x03'),
      ('Tab', '\t'),
      ('←', '\x1b[D'),
      ('↑', '\x1b[A'),
      ('↓', '\x1b[B'),
      ('→', '\x1b[C'),
    ];
    return ColoredBox(
      color: PocketTheme.terminalChrome,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(
              horizontal: PocketSpacing.xs,
              vertical: 5,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: keys.length,
            separatorBuilder: (_, _) => const SizedBox(width: PocketSpacing.xs),
            itemBuilder: (_, index) => OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: PocketTheme.terminalForeground,
                side: BorderSide(
                  color: MediaQuery.highContrastOf(context)
                      ? PocketTheme.terminalForeground
                      : PocketTheme.terminalBorder,
                  width: MediaQuery.highContrastOf(context) ? 1.5 : 1,
                ),
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: PocketSpacing.sm,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PocketRadii.sm),
                ),
              ),
              onPressed: () => terminal.textInput(keys[index].$2),
              child: Text(keys[index].$1),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalEmpty extends StatelessWidget {
  const _TerminalEmpty({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(PocketSpacing.lg),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(PocketRadii.md),
            ),
            child: Icon(
              Icons.terminal_rounded,
              size: 28,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: PocketSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: PocketSpacing.md),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    ),
  );
}
