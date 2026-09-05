import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_models.dart';
import '../app/app_services.dart';
import 'profile_form.dart';
import 'server_workspace_screen.dart';
import 'theme/pocket_theme.dart';

class PocketAgentApp extends StatefulWidget {
  const PocketAgentApp({super.key, required this.services, this.controller});

  final AppServices services;
  final PocketController? controller;

  @override
  State<PocketAgentApp> createState() => _PocketAgentAppState();
}

class _PocketAgentAppState extends State<PocketAgentApp> {
  late final PocketController controller;
  late final bool _ownsController;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    controller = widget.controller ?? PocketController(widget.services);
    controller.initialize();
  }

  @override
  void dispose() {
    if (_ownsController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Pocket Agent',
      theme: PocketTheme.light(),
      darkTheme: PocketTheme.dark(),
      highContrastTheme: PocketTheme.light(highContrast: true),
      highContrastDarkTheme: PocketTheme.dark(highContrast: true),
      themeMode: ThemeMode.system,
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final workspace = controller.activeWorkspace;
          if (workspace != null) {
            return ServerWorkspaceScreen(
              workspace: workspace,
              onBack: controller.closeServerView,
              confirmHostKey: _confirmHostKey,
            );
          }
          return ServerListScreen(
            controller: controller,
            confirmHostKey: _confirmHostKey,
          );
        },
      ),
    );
  }

  Future<bool> _confirmHostKey(HostKeyPrompt prompt) async {
    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) return false;
    final approved = await showDialog<bool>(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: const Text('确认主机身份'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('这是首次连接 ${prompt.host}:${prompt.port}。'),
              const SizedBox(height: 14),
              Text(
                prompt.keyType,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              SelectableText(
                prompt.fingerprint,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 14),
              const Text('请通过可信渠道核对指纹。确认后会固定此密钥；未来不一致时将自动阻止连接。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消连接'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('指纹一致，继续'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }
}

class ServerListScreen extends StatelessWidget {
  const ServerListScreen({
    super.key,
    required this.controller,
    required this.confirmHostKey,
  });

  final PocketController controller;
  final HostKeyConfirmer confirmHostKey;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final useCompactTitle = textScaler.scale(1) > 1.4;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: useCompactTitle ? textScaler.scale(27) + 32 : null,
        title: Semantics(
          header: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pocket Agent',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!useCompactTitle)
                Text(
                  '你的服务器工作台',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新服务器',
            onPressed: controller.loading ? null : controller.refreshServers,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _body(context, constraints.maxWidth),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, double width) {
    if (controller.loading) {
      return const _LoadingState();
    }
    if (controller.error != null && controller.servers.isEmpty) {
      return _CenteredState(
        icon: Icons.cloud_off_outlined,
        title: '服务器列表加载失败',
        message: controller.error!,
        actionIcon: Icons.refresh_rounded,
        actionLabel: '重试',
        onAction: controller.refreshServers,
      );
    }
    if (controller.servers.isEmpty) {
      return _CenteredState(
        icon: Icons.dns_outlined,
        title: '还没有服务器',
        message: '添加你的第一台 Linux 服务器。凭据只保存在系统安全存储中。',
        actionIcon: Icons.add_rounded,
        actionLabel: '添加服务器',
        onAction: () => _edit(context),
      );
    }
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final useSingleColumn = width < 720 || textScale > 1.25;
    Widget buildCard(BuildContext context, int index) {
      final server = controller.servers[index];
      return _ServerCard(
        server: server,
        onOpen: () => _open(context, server),
        onEdit: () => _edit(context, server),
        onDelete: () => _delete(context, server),
      );
    }

    final gridCardExtent = textScale > 1.1 ? 208.0 : 176.0;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            PocketSpacing.md,
            PocketSpacing.sm,
            PocketSpacing.md,
            PocketSpacing.md,
          ),
          sliver: SliverToBoxAdapter(
            child: _ServerListHeader(
              count: controller.servers.length,
              onAdd: () => _edit(context),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            PocketSpacing.md,
            0,
            PocketSpacing.md,
            104,
          ),
          sliver: useSingleColumn
              ? SliverList.separated(
                  itemBuilder: buildCard,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: PocketSpacing.sm),
                  itemCount: controller.servers.length,
                )
              : SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    buildCard,
                    childCount: controller.servers.length,
                  ),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 460,
                    mainAxisExtent: gridCardExtent,
                    crossAxisSpacing: PocketSpacing.sm,
                    mainAxisSpacing: PocketSpacing.sm,
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context, ServerSummary server) async {
    await controller.openServer(server, confirmHostKey);
  }

  Future<void> _edit(BuildContext context, [ServerSummary? server]) async {
    ProfileDraft? initial;
    if (server != null) {
      try {
        initial = await controller.services.loadServerDraft(server.id);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法读取服务器详情。')));
        }
        return;
      }
    }
    if (!context.mounted) return;
    final draft = await Navigator.of(context).push<ProfileDraft>(
      MaterialPageRoute(builder: (_) => ProfileFormScreen(initial: initial)),
    );
    if (draft == null) return;
    final saved = await controller.save(draft);
    if (context.mounted && saved == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请检查后重试。')));
    }
  }

  Future<void> _delete(BuildContext context, ServerSummary server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器？'),
        content: Text('将删除“${server.name}”的配置、凭据和固定的主机指纹。本地已打开的连接也会关闭。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteServer(server.id);
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });
  final ServerSummary server;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final authentication = server.authentication == AuthenticationKind.password
        ? '密码登录'
        : '密钥登录';
    return Card(
      key: ValueKey('server-card-${server.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(PocketSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(PocketRadii.sm),
                    ),
                    child: Icon(
                      Icons.dns_outlined,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: PocketSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: PocketSpacing.xxs),
                        Text(
                          '${server.username}@${server.host}:${server.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w500,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '服务器操作',
                    onSelected: (value) =>
                        value == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: PocketSpacing.md),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: PocketSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ServerMetadata(
                    icon: Icons.terminal_rounded,
                    label:
                        'SSH · $authentication · Codex ${server.remoteCodexPort}',
                  ),
                  const SizedBox(height: PocketSpacing.xs),
                  _ServerMetadata(
                    icon: Icons.shield_outlined,
                    label: server.hasPinnedHostKey ? '主机密钥已固定' : '首次连接需确认',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerMetadata extends StatelessWidget {
  const _ServerMetadata({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: PocketSpacing.xxs),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _ServerListHeader extends StatelessWidget {
  const _ServerListHeader({required this.count, required this.onAdd});

  final int count;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.25;
    final action = FilledButton.tonalIcon(
      key: const ValueKey('add-server'),
      onPressed: onAdd,
      icon: const Icon(Icons.add_rounded),
      label: const Text('添加服务器'),
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('已保存的服务器', style: theme.textTheme.titleMedium),
            ),
            Text(
              '$count 台',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: PocketSpacing.xxs),
        Text(
          '点按服务器以建立安全连接',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520 || largeText) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              const SizedBox(height: PocketSpacing.sm),
              Align(alignment: Alignment.centerRight, child: action),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            const SizedBox(width: PocketSpacing.md),
            action,
          ],
        );
      },
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Semantics(
        label: '正在加载服务器',
        child: const SizedBox.square(
          dimension: 32,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    ),
  );
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionIcon,
    required this.actionLabel,
    required this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final IconData actionIcon;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      PocketSpacing.xl,
      72,
      PocketSpacing.xl,
      PocketSpacing.xl,
    ),
    child: Align(
      alignment: Alignment.topCenter,
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
            const SizedBox(height: PocketSpacing.lg),
            FilledButton.icon(
              onPressed: onAction,
              icon: Icon(actionIcon),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    ),
  );
}
