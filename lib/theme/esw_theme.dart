import 'package:flutter/material.dart';
import 'esw_tokens.dart';

/// ESW 全局主题装配。所有颜色 / 圆角 / 字号均来自设计令牌。
class EswTheme {
  EswTheme._();

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: EswColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: EswColors.primary,
      surface: EswColors.page,
      onSurface: EswColors.textPrimary,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: EswColors.page,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: EswColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: EswText.title.copyWith(color: EswColors.textPrimary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: EswColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => EswText.bodySmall.copyWith(
            color: states.contains(WidgetState.selected)
                ? EswColors.primary
                : EswColors.ink3,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? EswColors.primary
                : EswColors.ink3,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: EswColors.primary,
          foregroundColor: EswColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
          ),
          minimumSize: const Size(64, 44),
          textStyle: EswText.bodyMedium,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: EswColors.primary,
          side: const BorderSide(color: EswColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
          ),
          minimumSize: const Size(64, 44),
          textStyle: EswText.bodyMedium,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: EswColors.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EswRadius.small),
          ),
          textStyle: EswText.bodyMedium,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: EswColors.card,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EswRadius.card),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: EswColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EswRadius.card),
        ),
        titleTextStyle: EswText.title.copyWith(color: EswColors.textPrimary),
        contentTextStyle: EswText.body.copyWith(color: EswColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: EswColors.card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: EswSpace.lg,
          vertical: EswSpace.md,
        ),
        hintStyle: EswText.body.copyWith(color: EswColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EswRadius.control),
          borderSide: const BorderSide(color: EswColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EswRadius.control),
          borderSide: const BorderSide(color: EswColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EswRadius.control),
          borderSide: const BorderSide(color: EswColors.primary, width: 1.5),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: EswColors.textPrimary,
        contentTextStyle: EswText.body.copyWith(color: EswColors.card),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EswRadius.control),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: EswColors.border,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
