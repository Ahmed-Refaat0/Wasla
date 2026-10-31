import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(
    WaslaApp(
      initialDarkMode: preferences.getBool('dark_mode') ?? false,
      initialPrimaryColor: Color(
        preferences.getInt('primary_color') ?? 0xFF167D76,
      ),
    ),
  );
}
