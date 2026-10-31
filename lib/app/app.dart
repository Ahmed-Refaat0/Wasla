import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/home/presentation/dashboard_screen.dart';
import 'theme/app_theme.dart';

class WaslaApp extends StatefulWidget {
  const WaslaApp({
    super.key,
    required this.initialDarkMode,
    required this.initialPrimaryColor,
  });

  final bool initialDarkMode;
  final Color initialPrimaryColor;

  @override
  State<WaslaApp> createState() => _WaslaAppState();
}

class _WaslaAppState extends State<WaslaApp> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialDarkMode;
    AppColors.primaryColor = widget.initialPrimaryColor;
    AppColors.isDarkMode = _isDarkMode;
  }

  Future<void> _toggleTheme() async {
    final nextMode = !_isDarkMode;
    setState(() {
      _isDarkMode = nextMode;
      AppColors.isDarkMode = nextMode;
    });
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool('dark_mode', nextMode);
    if (!saved) {
      throw StateError('Could not save the selected appearance.');
    }
  }

  Future<void> _setPrimaryColor(Color color) async {
    setState(() {
      AppColors.primaryColor = color;
    });
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setInt('primary_color', color.toARGB32());
    if (!saved) {
      throw StateError('Could not save the selected accent color.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'وصلة',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      themeAnimationDuration: const Duration(milliseconds: 350),
      themeAnimationCurve: Curves.easeInOutCubic,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: DashboardScreen(
        isDarkMode: _isDarkMode,
        onToggleTheme: _toggleTheme,
        onSetPrimaryColor: _setPrimaryColor,
      ),
    );
  }
}
