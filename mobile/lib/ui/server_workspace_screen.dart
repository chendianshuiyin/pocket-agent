import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_models.dart';
import 'codex_pane.dart';
import 'terminal_pane.dart';
import 'theme/pocket_theme.dart';
import 'widgets/pocket_glass_surface.dart';

class ServerWorkspaceScreen extends StatefulWidget {
  const ServerWorkspaceScreen({
    super.key,
    required this.workspace,
    required this.onBack,
    required this.confirmHostKey,
  });

  final ServerWorkspace workspace;
  final VoidCallback onBack;
  final HostKeyConfirmer confirmHostKey;

  @override
  State<ServerWorkspaceScreen> createState() => _ServerWorkspaceScreenState();
}

class _ServerWorkspaceScreenState extends State<ServerWorkspaceScreen> {
  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant ServerWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      oldWidget.workspace.removeListener(_refresh);
      widget.workspace.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final textScaler = MediaQuery.textScalerOf(context);
    final largeText = textScaler.scale(1) > 1.4;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: largeText ? textScaler.scale(38) + 24 : null,
        leading: IconButton(
          tooltip: '返回服务器',
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workspace.server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _ConnectionLabel(link: workspace.link),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            tooltip: '重新连接',
            onPressed: workspace.busy
                ? null
                : () => workspace.reconnect(widget.confirmHostKey),
            icon: const Icon(Icons.sync_rounded),
          ),
          const SizedBox(width: PocketSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (workspace.error != null)
              MaterialBanner(
                content: Text(workspace.error!),
                leading: const Icon(Icons.warning_amber_rounded),
                actions: [
                  TextButton(
                    onPressed: () => workspace.reconnect(widget.confirmHostKey),
                    child: const Text('重连'),
                  ),
                ],
              ),
            Expanded(
              child: IndexedStack(
                index: workspace.selectedFeature,
                children: [
                  TerminalPane(workspace: workspace),
                  CodexPane(workspace: workspace),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(
          PocketSpacing.sm,
          PocketSpacing.xs,
          PocketSpacing.sm,
          PocketSpacing.sm,
        ),
        child: PocketGlassSurface(
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            selectedIndex: workspace.selectedFeature,
            onDestinationSelected: (value) {
              workspace.selectFeature(value);
              if (value == 1) workspace.openCodex();
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal_rounded),
                label: 'SSH',
              ),
              NavigationDestination(
                icon: Icon(Icons.forum_outlined),
                selectedIcon: Icon(Icons.forum_rounded),
                label: 'Codex',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionLabel extends StatelessWidget {
  const _ConnectionLabel({required this.link});
  final LinkSnapshot link;
  @override
  Widget build(BuildContext context) {
    final semantics = PocketSemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (link.phase) {
      LinkPhase.connected => (semantics.success, 'SSH 已连接'),
      LinkPhase.connecting => (semantics.warning, '正在连接…'),
      LinkPhase.failed => (scheme.error, '连接失败'),
      LinkPhase.disconnected => (scheme.onSurfaceVariant, '已断开'),
    };
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: PocketSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
