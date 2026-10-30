import 'package:flutter/material.dart';

abstract final class AppColors {
  static bool isDarkMode = false;

  static Color get canvas =>
      isDarkMode ? const Color(0xFF101719) : const Color(0xFFF5F8F9);
  static Color get surface =>
      isDarkMode ? const Color(0xFF1A2427) : Colors.white;
  static Color get ink =>
      isDarkMode ? const Color(0xFFE7F0F1) : const Color(0xFF172B36);
  static Color get muted =>
      isDarkMode ? const Color(0xFFA3B2B5) : const Color(0xFF71818A);
  static Color get line =>
      isDarkMode ? const Color(0xFF2C3A3E) : const Color(0xFFE7EDEF);
  static Color get brand =>
      isDarkMode ? const Color(0xFF64C9BE) : const Color(0xFF167D76);
  static Color get brandDark =>
      isDarkMode ? const Color(0xFF91DDD4) : const Color(0xFF11645F);
  static Color get brandTint =>
      isDarkMode ? const Color(0xFF203936) : const Color(0xFFE9F5F3);
  static Color get blueTint =>
      isDarkMode ? const Color(0xFF252F48) : const Color(0xFFEEF3FF);
  static Color get blue =>
      isDarkMode ? const Color(0xFFA8BAFF) : const Color(0xFF4A68B8);
  static Color get tile =>
      isDarkMode ? const Color(0xFF151F22) : const Color(0xFFFAFCFC);
  static Color get dropSurface =>
      isDarkMode ? const Color(0xFF1D302E) : const Color(0xFFF7FBFA);
  static Color get dropBorder =>
      isDarkMode ? const Color(0xFF38635D) : const Color(0xFFB8DCD7);
  static Color get orangeTint =>
      isDarkMode ? const Color(0xFF3A2D20) : const Color(0xFFFFF3E8);
  static Color get orange =>
      isDarkMode ? const Color(0xFFF1B66D) : const Color(0xFFC47B32);
  static Color get danger =>
      isDarkMode ? const Color(0xFFFF947E) : Colors.deepOrange;
  static Color get shadow =>
      isDarkMode ? Colors.transparent : const Color(0x07172B36);
  static Color get onBrand =>
      isDarkMode ? const Color(0xFF102322) : Colors.white;
  static Color get snackbar =>
      isDarkMode ? const Color(0xFF29383C) : const Color(0xFF172B36);
}

abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colors = isDark
        ? const (
            canvas: Color(0xFF101719),
            surface: Color(0xFF1A2427),
            ink: Color(0xFFE7F0F1),
            muted: Color(0xFFA3B2B5),
            line: Color(0xFF2C3A3E),
            brand: Color(0xFF64C9BE),
          )
        : const (
            canvas: Color(0xFFF5F8F9),
            surface: Colors.white,
            ink: Color(0xFF172B36),
            muted: Color(0xFF71818A),
            line: Color(0xFFE7EDEF),
            brand: Color(0xFF167D76),
          );
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: colors.brand,
          brightness: brightness,
          surface: colors.surface,
        ).copyWith(
          primary: colors.brand,
          onPrimary: isDark ? const Color(0xFF102322) : Colors.white,
          surface: colors.surface,
          onSurface: colors.ink,
          onSurfaceVariant: colors.muted,
          outline: colors.line,
          error: isDark ? const Color(0xFFFF947E) : Colors.deepOrange,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.canvas,
      cardColor: colors.surface,
      dividerColor: colors.line,
      dialogTheme: DialogThemeData(backgroundColor: colors.surface),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.snackbar,
        contentTextStyle: const TextStyle(color: Colors.white),
      ),
      fontFamily: null,
      textTheme: TextTheme(
        headlineMedium: TextStyle(
          color: colors.ink,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
        titleLarge: TextStyle(
          color: colors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: TextStyle(
          color: colors.ink,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: colors.ink, fontSize: 15, height: 1.6),
        bodyMedium: TextStyle(color: colors.muted, fontSize: 13, height: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.brand,
          foregroundColor: colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.ink,
          side: BorderSide(color: colors.line),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      iconTheme: IconThemeData(color: colors.muted),
    );
  }
}
