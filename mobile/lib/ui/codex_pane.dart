import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_models.dart';
import '../app/app_services.dart';
import 'theme/pocket_theme.dart';

class CodexPane extends StatefulWidget {
  const CodexPane({super.key, required this.workspace});
  final ServerWorkspace workspace;

  @override
  State<CodexPane> createState() => _CodexPaneState();
}

class _CodexPaneState extends State<CodexPane> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  SkillChoice? _skill;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.workspace.codexSnapshot;
    if (snapshot.loading && widget.workspace.codex == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: PocketSpacing.md),
            Text(
              '正在启动远程 Codex…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (snapshot.error != null && widget.workspace.codex == null) {
      return _CodexError(
        message: snapshot.error!,
        retry: widget.workspace.retryCodex,
      );
    }
    if (widget.workspace.codex == null) {
      return _CodexEmptyState(
        icon: Icons.forum_outlined,
        title: '连接远程 Codex',
        message: '通过当前 SSH tunnel 安全访问任务与对话。',
        actionLabel: '连接 Codex',
        onAction: widget.workspace.openCodex,
      );
    }
    return Column(
      children: [
        if (snapshot.accountState == RemoteAccountState.signedOut)
          MaterialBanner(
            leading: Icon(
              Icons.key_off_outlined,
              color: PocketSemanticColors.of(context).warning,
            ),
            content: const Text(
              '远端 Codex 尚未登录。请在 SSH 终端运行 codex login --device-auth。',
            ),
            actions: [
              TextButton(
                onPressed: () => widget.workspace.selectFeature(0),
                child: const Text('前往 SSH'),
              ),
            ],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 720 &&
                  MediaQuery.textScalerOf(context).scale(1) <= 1.25;
              if (wide) {
                return Row(
                  children: [
                    SizedBox(
                      width: 290,
                      child: _ThreadList(
                        snapshot: snapshot,
                        port: widget.workspace.codex!,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _Conversation(
                        snapshot: snapshot,
                        port: widget.workspace.codex!,
                        composer: _buildComposer(snapshot),
                      ),
                    ),
                  ],
                );
              }
              if (snapshot.activeThreadId == null) {
                return _ThreadList(
                  snapshot: snapshot,
                  port: widget.workspace.codex!,
                );
              }
              return _Conversation(
                snapshot: snapshot,
                port: widget.workspace.codex!,
                onBack: widget.workspace.showCodexThreadList,
                composer: _buildComposer(snapshot),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(CodexWorkspaceSnapshot snapshot) {
    final running =
        snapshot.runState == ThreadRunState.running ||
        snapshot.runState == ThreadRunState.waitingApproval;
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_skill != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PocketSpacing.sm,
                  PocketSpacing.xs,
                  PocketSpacing.sm,
                  0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    avatar: const Icon(Icons.extension_outlined, size: 17),
                    label: Text(_skill!.name),
                    onDeleted: () => setState(() => _skill = null),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PocketSpacing.sm,
                PocketSpacing.xs,
                PocketSpacing.sm,
                PocketSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey('codex-actions'),
                    tooltip: '命令与技能',
                    onPressed: running ? null : _openActions,
                    icon: const Icon(Icons.add_rounded),
                  ),
                  const SizedBox(width: PocketSpacing.xs),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('codex-composer'),
                      controller: _composer,
                      enabled: !running,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: running ? '任务运行中…' : '给 Codex 发送消息',
                        suffixIcon: running
                            ? IconButton(
                                tooltip: '中断任务',
                                onPressed: widget.workspace.codex!.interrupt,
                                icon: const Icon(Icons.stop_circle_outlined),
                              )
                            : IconButton.filled(
                                tooltip: '发送',
                                onPressed: _send,
                                icon: const Icon(Icons.arrow_upward_rounded),
                              ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty && _skill == null) return;
    _composer.clear();
    final skill = _skill;
    setState(() => _skill = null);
    await widget.workspace.codex!.send(text, skill: skill);
  }

  Future<void> _openActions() async {
    final snapshot = widget.workspace.codexSnapshot;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              ListTile(
                title: Text(
                  '命令',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final command in const [
                ('/review', '审查当前未提交更改', Icons.rate_review_outlined),
                ('/compact', '压缩当前任务上下文', Icons.compress_rounded),
                ('/status', '查看当前任务状态', Icons.info_outline_rounded),
              ])
                ListTile(
                  leading: Icon(command.$3),
                  title: Text(
                    command.$1,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                  subtitle: Text(command.$2),
                  onTap: () => Navigator.pop(context, command.$1),
                ),
              const Divider(),
              ListTile(
                title: Text(
                  '技能',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                subtitle: const Text('显式选择一个技能随下一条消息发送'),
              ),
              if (snapshot.skills.isEmpty)
                const ListTile(
                  leading: Icon(Icons.extension_off_outlined),
                  title: Text('没有可用技能'),
                )
              else
                for (final skill in snapshot.skills)
                  ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: Text(skill.name),
                    subtitle: skill.description == null
                        ? null
                        : Text(
                            skill.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => Navigator.pop(context, skill),
                  ),
            ],
          ),
        ),
      ),
    );
    if (choice is SkillChoice) setState(() => _skill = choice);
    if (choice is String) {
      await widget.workspace.codex!.runCommand(choice);
    }
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({required this.snapshot, required this.port});
  final CodexWorkspaceSnapshot snapshot;
  final CodexPort port;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _ThreadListHeader(snapshot: snapshot, port: port),
      if (snapshot.loading) const LinearProgressIndicator(minHeight: 2),
      if (snapshot.error != null)
        Padding(
          padding: const EdgeInsets.all(PocketSpacing.sm),
          child: Text(
            snapshot.error!,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: snapshot.threads.isEmpty && !snapshot.loading
            ? const _CodexEmptyState(
                icon: Icons.chat_bubble_outline_rounded,
                title: '暂无任务',
                message: '创建一个任务，从手机继续工作。',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  PocketSpacing.xs,
                  PocketSpacing.xxs,
                  PocketSpacing.xs,
                  PocketSpacing.lg,
                ),
                itemCount:
                    snapshot.threads.length +
                    (snapshot.nextThreadCursor == null ? 0 : 1),
                separatorBuilder: (_, _) =>
                    const SizedBox(height: PocketSpacing.xs),
                itemBuilder: (context, index) {
                  if (index == snapshot.threads.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: OutlinedButton.icon(
                          key: const ValueKey('load-more-codex-threads'),
                          onPressed: snapshot.loadingMoreThreads
                              ? null
                              : port.loadMoreThreads,
                          icon: snapshot.loadingMoreThreads
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.expand_more_rounded),
                          label: Text(
                            snapshot.loadingMoreThreads ? '正在加载…' : '加载更多',
                          ),
                        ),
                      ),
                    );
                  }
                  final thread = snapshot.threads[index];
                  final running =
                      thread.state == ThreadRunState.running ||
                      (thread.id == snapshot.activeThreadId &&
                          (snapshot.runState == ThreadRunState.running ||
                              snapshot.runState ==
                                  ThreadRunState.waitingApproval));
                  return ListTile(
                    key: ValueKey('codex-thread-${thread.id}'),
                    selected: thread.id == snapshot.activeThreadId,
                    tileColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerLowest,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    contentPadding: const EdgeInsets.fromLTRB(
                      PocketSpacing.sm,
                      PocketSpacing.xs,
                      PocketSpacing.xs,
                      PocketSpacing.xs,
                    ),
                    minVerticalPadding: PocketSpacing.sm,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(PocketRadii.md),
                      side: BorderSide(
                        color: thread.id == snapshot.activeThreadId
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    leading: _RunIndicator(state: thread.state),
                    title: Text(
                      thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      thread.preview.isEmpty ? '暂无预览' : thread.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      key: ValueKey('codex-thread-actions-${thread.id}'),
                      tooltip: '任务操作',
                      onSelected: (_) =>
                          _confirmArchiveThread(context, port, thread),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'archive',
                          enabled: !running,
                          child: Row(
                            children: [
                              const Icon(Icons.archive_outlined),
                              const SizedBox(width: 10),
                              Text(running ? '运行中，无法归档' : '归档任务'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    onTap: () => port.openThread(thread.id),
                  );
                },
              ),
      ),
    ],
  );
}

class _ThreadListHeader extends StatelessWidget {
  const _ThreadListHeader({required this.snapshot, required this.port});

  final CodexWorkspaceSnapshot snapshot;
  final CodexPort port;

  @override
  Widget build(BuildContext context) {
    final disabled = snapshot.loading || snapshot.loadingMoreThreads;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.25;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 390 || largeText;
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '刷新任务',
              onPressed: disabled ? null : port.refreshThreads,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: PocketSpacing.xs),
            FilledButton.icon(
              key: const ValueKey('new-codex-thread'),
              onPressed: disabled
                  ? null
                  : () => _promptNewThread(context, port),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新任务'),
            ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            PocketSpacing.sm,
            PocketSpacing.xs,
            PocketSpacing.xs,
            PocketSpacing.xs,
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('任务', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: PocketSpacing.xs),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        '任务',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

Future<void> _confirmArchiveThread(
  BuildContext context,
  CodexPort port,
  ThreadSummary thread,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('归档任务？'),
      content: Text('“${thread.title}”将从当前任务列表中移除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton.tonal(
          key: const ValueKey('confirm-archive-thread'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('归档'),
        ),
      ],
    ),
  );
  if (confirmed == true) await port.archiveThread(thread.id);
}

Future<void> _promptNewThread(BuildContext context, CodexPort port) async {
  var cwdDraft = '';
  final cwd = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('新建任务'),
      content: TextField(
        key: const ValueKey('new-thread-cwd'),
        autofocus: true,
        autocorrect: false,
        onChanged: (value) => cwdDraft = value,
        decoration: const InputDecoration(
          labelText: '工作目录（可选）',
          hintText: '/home/user/project',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-new-thread'),
          onPressed: () => Navigator.pop(context, cwdDraft.trim()),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  if (cwd != null) await port.createThread(cwd: cwd.isEmpty ? null : cwd);
}

class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.snapshot,
    required this.port,
    required this.composer,
    this.onBack,
  });
  final CodexWorkspaceSnapshot snapshot;
  final CodexPort port;
  final Widget composer;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PocketSpacing.xs),
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    tooltip: '返回任务列表',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                const SizedBox(width: PocketSpacing.xs),
                Expanded(
                  child: Text(
                    '${_stateLabel(snapshot.runState)}${snapshot.activeModel == null ? '' : ' · ${snapshot.activeModel}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _stateColor(context, snapshot.runState),
                    ),
                  ),
                ),
                if (snapshot.runState == ThreadRunState.running)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: PocketSpacing.xs),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (snapshot.models.isNotEmpty)
                  PopupMenuButton<String>(
                    key: const ValueKey('codex-model-picker'),
                    tooltip: '选择模型',
                    icon: const Icon(Icons.tune_rounded),
                    initialValue: snapshot.activeModel,
                    onSelected: port.selectModel,
                    itemBuilder: (context) => snapshot.models
                        .map(
                          (model) => PopupMenuItem(
                            key: ValueKey('codex-model-${model.id}'),
                            value: model.id,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(model.label),
                              subtitle:
                                  model.description == null ||
                                      model.description!.isEmpty
                                  ? null
                                  : Text(
                                      model.description!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: model.id == snapshot.activeModel
                                  ? const Icon(Icons.check_rounded)
                                  : null,
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
              ],
            ),
          ),
        ),
      ),
      Expanded(
        child: snapshot.timeline.isEmpty
            ? const _CodexEmptyState(
                icon: Icons.chat_outlined,
                title: '开始对话',
                message: '发送消息继续这项任务。',
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  PocketSpacing.sm,
                  PocketSpacing.sm,
                  PocketSpacing.sm,
                  PocketSpacing.lg,
                ),
                itemCount: snapshot.timeline.length,
                itemBuilder: (context, index) =>
                    _TimelineCard(item: snapshot.timeline[index]),
              ),
      ),
      if (snapshot.approval != null)
        _ApprovalCard(prompt: snapshot.approval!, port: port),
      if (snapshot.userInput != null)
        _UserInputCard(prompt: snapshot.userInput!, port: port),
      composer,
    ],
  );

  static String _stateLabel(ThreadRunState state) => switch (state) {
    ThreadRunState.running => '正在运行',
    ThreadRunState.waitingApproval => '等待你的确认',
    ThreadRunState.error => '运行失败',
    ThreadRunState.completed => '已完成',
    ThreadRunState.idle => '可以继续',
  };
  static Color _stateColor(BuildContext context, ThreadRunState state) =>
      switch (state) {
        ThreadRunState.error => Theme.of(context).colorScheme.error,
        ThreadRunState.waitingApproval => PocketSemanticColors.of(
          context,
        ).warning,
        ThreadRunState.running => Theme.of(context).colorScheme.primary,
        _ => Theme.of(context).colorScheme.onSurfaceVariant,
      };
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.item});
  final TimelineItem item;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = item.kind == TimelineKind.user;
    final tool = item.kind == TimelineKind.tool;
    final error = item.kind == TimelineKind.error;
    final background = error
        ? scheme.errorContainer
        : user
        ? scheme.primaryContainer
        : tool
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLowest;
    final foreground = error
        ? scheme.onErrorContainer
        : user
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    return Align(
      key: ValueKey('codex-timeline-${item.kind.name}-${item.id}'),
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        margin: const EdgeInsets.only(bottom: PocketSpacing.sm),
        padding: const EdgeInsets.all(PocketSpacing.sm),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(PocketRadii.md),
          border: Border.all(
            color: error ? scheme.error : scheme.outlineVariant,
            width: MediaQuery.highContrastOf(context) ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.title != null) ...[
              Text(
                item.title!,
                style: theme.textTheme.labelLarge?.copyWith(color: foreground),
              ),
              const SizedBox(height: PocketSpacing.xs),
            ],
            SelectableText(
              item.text,
              style:
                  (tool
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        color: foreground,
                        fontFamily: tool ? 'monospace' : null,
                      ),
            ),
            if (item.inProgress) ...[
              const SizedBox(height: PocketSpacing.xs),
              const LinearProgressIndicator(minHeight: 2),
            ],
          ],
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.prompt, required this.port});
  final ApprovalPrompt prompt;
  final CodexPort port;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = PocketSemanticColors.of(context).warning;
    final highContrast = MediaQuery.highContrastOf(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        PocketSpacing.sm,
        PocketSpacing.xs,
        PocketSpacing.sm,
        PocketSpacing.xxs,
      ),
      padding: const EdgeInsets.all(PocketSpacing.sm),
      decoration: BoxDecoration(
        color: highContrast
            ? theme.colorScheme.surfaceContainerLowest
            : warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(PocketRadii.md),
        border: Border.all(color: warning, width: highContrast ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gpp_maybe_outlined, color: warning),
              const SizedBox(width: PocketSpacing.xs),
              Expanded(
                child: Text(prompt.title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: PocketSpacing.xs),
          Text(prompt.details, maxLines: 4, overflow: TextOverflow.ellipsis),
          const SizedBox(height: PocketSpacing.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: PocketSpacing.xs,
            runSpacing: PocketSpacing.xs,
            children: [
              TextButton(
                onPressed: () => port.decideApproval(prompt, approved: false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => port.decideApproval(prompt, approved: true),
                child: const Text('允许一次'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UserInputCard extends StatelessWidget {
  const _UserInputCard({required this.prompt, required this.port});
  final UserInputPrompt prompt;
  final CodexPort port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        PocketSpacing.sm,
        PocketSpacing.xs,
        PocketSpacing.sm,
        PocketSpacing.xxs,
      ),
      padding: const EdgeInsets.all(PocketSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(PocketRadii.md),
        border: Border.all(
          color: MediaQuery.highContrastOf(context)
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: MediaQuery.highContrastOf(context) ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.question_answer_outlined,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: PocketSpacing.xs),
              Expanded(
                child: Text(
                  'Codex 有 ${prompt.questions.length} 个问题需要你回答',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PocketSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () => _answer(context),
              child: const Text('填写回复'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _answer(BuildContext context) async {
    final draft = <String, String>{};
    final answers = await showDialog<Map<String, List<String>>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回复 Codex'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: prompt.questions
                  .map(
                    (question) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: TextFormField(
                        minLines: 1,
                        maxLines: 4,
                        onChanged: (value) => draft[question.id] = value,
                        decoration: InputDecoration(
                          labelText: question.prompt,
                          helperText: question.options.isEmpty
                              ? null
                              : '可选：${question.options.join(' / ')}',
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('暂不回答'),
          ),
          FilledButton(
            onPressed: () {
              final values = <String, List<String>>{};
              for (final question in prompt.questions) {
                final value = draft[question.id]?.trim() ?? '';
                if (value.isNotEmpty) values[question.id] = [value];
              }
              if (values.length == prompt.questions.length) {
                Navigator.pop(dialogContext, values);
              }
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (answers != null) await port.answerUserInput(prompt, answers);
  }
}

class _RunIndicator extends StatelessWidget {
  const _RunIndicator({required this.state});
  final ThreadRunState state;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantics = PocketSemanticColors.of(context);
    if (state == ThreadRunState.running) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final (icon, color) = switch (state) {
      ThreadRunState.error => (Icons.error_outline_rounded, scheme.error),
      ThreadRunState.completed => (
        Icons.check_circle_outline_rounded,
        semantics.success,
      ),
      ThreadRunState.waitingApproval => (
        Icons.gpp_maybe_outlined,
        semantics.warning,
      ),
      _ => (Icons.chat_bubble_outline_rounded, scheme.onSurfaceVariant),
    };
    return Icon(icon, size: 20, color: color);
  }
}

class _CodexEmptyState extends StatelessWidget {
  const _CodexEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(PocketSpacing.lg),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
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
                icon,
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
            const SizedBox(height: PocketSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: PocketSpacing.lg),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.power_settings_new_rounded),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _CodexError extends StatelessWidget {
  const _CodexError({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;
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
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(PocketRadii.md),
            ),
            child: Icon(
              Icons.cloud_off_outlined,
              size: 28,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: PocketSpacing.md),
          Text('Codex 连接失败', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: PocketSpacing.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: PocketSpacing.lg),
          FilledButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.sync_rounded),
            label: const Text('手动重连'),
          ),
        ],
      ),
    ),
  );
}
