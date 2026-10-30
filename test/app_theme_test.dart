import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/app/theme/app_theme.dart';

void main() {
  tearDown(() {
    AppColors.isDarkMode = false;
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
}
