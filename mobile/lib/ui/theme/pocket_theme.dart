import 'package:flutter/material.dart';

abstract final class PocketSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const EdgeInsets screen = EdgeInsets.symmetric(horizontal: md);
}

abstract final class PocketRadii {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double round = 999;
}

abstract final class PocketTheme {
  static const Color _seed = Color(0xff555dbf);
  static const Color terminalBackground = Color(0xff0b0d12);
  static const Color terminalChrome = Color(0xff151824);
  static const Color terminalBorder = Color(0xff3a3e52);
  static const Color terminalForeground = Color(0xfff1f0f7);

  static ThemeData light({bool highContrast = false}) =>
      _build(brightness: Brightness.light, highContrast: highContrast);

  static ThemeData dark({bool highContrast = false}) =>
      _build(brightness: Brightness.dark, highContrast: highContrast);

  static ThemeData _build({
    required Brightness brightness,
    required bool highContrast,
  }) {
    final isDark = brightness == Brightness.dark;
    final generated = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
      contrastLevel: highContrast ? 1 : 0,
    );
    final scheme = generated.copyWith(
      primary: isDark
          ? (highContrast ? const Color(0xffd4d5ff) : const Color(0xffb7baff))
          : (highContrast ? const Color(0xff3d449a) : const Color(0xff555dbf)),
      onPrimary: isDark ? const Color(0xff20243a) : const Color(0xffffffff),
      primaryContainer: isDark
          ? const Color(0xff3f456f)
          : const Color(0xffe7e8ff),
      onPrimaryContainer: isDark
          ? const Color(0xfff1f0f7)
          : const Color(0xff20243a),
      surface: isDark ? const Color(0xff11131c) : const Color(0xfff8f6f1),
      onSurface: isDark ? const Color(0xfff1f0f7) : const Color(0xff20243a),
      onSurfaceVariant: isDark
          ? const Color(0xffb8b7c6)
          : const Color(0xff666b80),
      surfaceContainerLowest: isDark
          ? const Color(0xff191c28)
          : const Color(0xfffffefb),
      surfaceContainerLow: isDark
          ? const Color(0xff1d202d)
          : const Color(0xfff3f1ed),
      surfaceContainer: isDark
          ? const Color(0xff232633)
          : const Color(0xffeceaf0),
      surfaceContainerHigh: isDark
          ? const Color(0xff2a2d3b)
          : const Color(0xffe5e3ea),
      outlineVariant: isDark
          ? const Color(0xff343746)
          : const Color(0xffdfdee7),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );
    final textTheme = _textTheme(base.textTheme, scheme);
    final borderSide = BorderSide(
      color: scheme.outlineVariant,
      width: highContrast ? 1.5 : 1,
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        toolbarHeight: 72,
        titleSpacing: PocketSpacing.lg,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PocketRadii.lg),
          side: borderSide,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: highContrast ? 1.5 : 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PocketRadii.md),
          borderSide: borderSide,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PocketRadii.md),
          borderSide: borderSide,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PocketRadii.md),
          borderSide: BorderSide(
            color: scheme.primary,
            width: highContrast ? 2.5 : 2,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: PocketSpacing.md,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(
            horizontal: PocketSpacing.lg,
            vertical: PocketSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PocketRadii.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PocketRadii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(
            horizontal: PocketSpacing.md,
            vertical: PocketSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
          side: borderSide,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PocketRadii.md),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(48)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: active ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PocketRadii.lg),
          side: borderSide,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PocketRadii.md),
          side: borderSide,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(PocketRadii.lg),
          ),
        ),
      ),
      bannerTheme: MaterialBannerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        contentTextStyle: textTheme.bodyMedium,
        padding: const EdgeInsets.symmetric(
          horizontal: PocketSpacing.md,
          vertical: PocketSpacing.xs,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PocketRadii.md),
        ),
      ),
      extensions: [
        PocketSemanticColors(
          success: isDark ? const Color(0xff7dd8af) : const Color(0xff2f6b55),
          warning: isDark ? const Color(0xfff0bb68) : const Color(0xff8a5700),
        ),
      ],
    );
  }

  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) =>
      base.copyWith(
        headlineSmall: base.headlineSmall?.copyWith(
          fontSize: 26,
          height: 1.18,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        titleLarge: base.titleLarge?.copyWith(
          fontSize: 22,
          height: 1.22,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontSize: 16,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 14.5, height: 1.42),
        bodySmall: base.bodySmall?.copyWith(fontSize: 12.5, height: 1.38),
        labelLarge: base.labelLarge?.copyWith(
          fontSize: 14,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.labelMedium?.copyWith(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
      );
}

@immutable
class PocketSemanticColors extends ThemeExtension<PocketSemanticColors> {
  const PocketSemanticColors({required this.success, required this.warning});

  final Color success;
  final Color warning;

  static PocketSemanticColors of(BuildContext context) =>
      Theme.of(context).extension<PocketSemanticColors>()!;

  @override
  PocketSemanticColors copyWith({Color? success, Color? warning}) =>
      PocketSemanticColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
      );

  @override
  PocketSemanticColors lerp(covariant PocketSemanticColors? other, double t) {
    if (other == null) return this;
    return PocketSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
