import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/home/presentation/home_screen.dart';
import 'theme/app_theme.dart';

class WaslaApp extends StatefulWidget {
  const WaslaApp({super.key, required this.initialDarkMode});

  final bool initialDarkMode;

  @override
  State<WaslaApp> createState() => _WaslaAppState();
}

class _WaslaAppState extends State<WaslaApp> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialDarkMode;
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'وصلة',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(isDarkMode: _isDarkMode, onToggleTheme: _toggleTheme),
    );
  }
}
