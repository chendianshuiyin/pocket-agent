import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/pocket_theme.dart';

/// A small, clipped material treatment for navigation and floating controls.
/// Content surfaces should remain opaque for predictable contrast.
class PocketGlassSurface extends StatelessWidget {
  const PocketGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(PocketRadii.lg)),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: highContrast
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLowest.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.92 : 0.82,
              ),
        borderRadius: borderRadius,
        border: Border.all(
          color: highContrast ? scheme.outline : scheme.outlineVariant,
          width: highContrast ? 1.5 : 1,
        ),
      ),
      child: child,
    );

    if (highContrast) {
      return ClipRRect(borderRadius: borderRadius, child: surface);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: surface,
      ),
    );
  }
}

class PocketGlassAction extends StatelessWidget {
  const PocketGlassAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PocketGlassSurface(
      borderRadius: const BorderRadius.all(Radius.circular(PocketRadii.md)),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(PocketRadii.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PocketSpacing.md,
                vertical: PocketSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: PocketSpacing.xs),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
