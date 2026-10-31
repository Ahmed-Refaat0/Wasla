import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/app/theme/app_theme.dart';

void main() {
  tearDown(() {
    AppColors.isDarkMode = false;
    AppColors.primaryColor = const Color(0xFF167D76);
  });

  test('dark theme uses dark surfaces and readable foregrounds', () {
    AppColors.isDarkMode = true;

    expect(AppTheme.dark.brightness, Brightness.dark);
    expect(AppTheme.dark.scaffoldBackgroundColor, AppColors.canvas);
    expect(AppTheme.dark.colorScheme.surface, AppColors.surface);
    expect(AppColors.ink, const Color(0xFFE7F0F1));
    expect(AppColors.surface, const Color(0xFF1A2427));
    expect(AppColors.brandTint, const Color(0xFF203936));
  });

  test('light theme palette remains the default appearance', () {
    AppColors.isDarkMode = false;

    expect(AppTheme.light.brightness, Brightness.light);
    expect(AppTheme.light.scaffoldBackgroundColor, AppColors.canvas);
    expect(AppColors.surface, Colors.white);
    expect(AppColors.brand, const Color(0xFF167D76));
  });

  test('custom accent color updates light and dark theme palettes', () {
    const accent = Color(0xFF8757C6);
    AppColors.primaryColor = accent;

    expect(AppTheme.light.colorScheme.primary, accent);
    expect(AppColors.brand, accent);

    AppColors.isDarkMode = true;
    expect(AppTheme.dark.colorScheme.primary, AppColors.brand);
    expect(AppColors.brand, isNot(accent));
  });
}
