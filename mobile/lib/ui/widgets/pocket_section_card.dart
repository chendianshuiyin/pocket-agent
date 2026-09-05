import 'package:flutter/material.dart';

import '../theme/pocket_theme.dart';

class PocketSectionCard extends StatelessWidget {
  const PocketSectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.caption,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(PocketSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(PocketRadii.sm),
                  ),
                  child: Icon(icon, size: 21, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: PocketSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: PocketSpacing.xxs),
                      Text(
                        caption,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: PocketSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}
