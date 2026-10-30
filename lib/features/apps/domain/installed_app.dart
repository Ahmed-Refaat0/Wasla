import 'dart:typed_data';

class InstalledApp {
  const InstalledApp({
    required this.name,
    required this.packageName,
    required this.apkPaths,
    required this.apkSizes,
    this.versionName,
    this.iconBytes,
  });

  final String name;
  final String packageName;
  final List<String> apkPaths;
  final List<int> apkSizes;
  final String? versionName;
  final Uint8List? iconBytes;
}
