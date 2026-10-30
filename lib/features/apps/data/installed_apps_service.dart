import 'dart:io';

import 'package:flutter/services.dart';

import '../../transfer/domain/transfer_file_source.dart';
import '../domain/installed_app.dart';

class InstalledAppsService {
  InstalledAppsService({
    MethodChannel methodChannel = const MethodChannel('wasla/installed_apps'),
    bool Function()? isAndroid,
  }) : _channel = methodChannel,
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final MethodChannel _channel;
  final bool Function() _isAndroid;

  Future<List<InstalledApp>> listUserApps() async {
    if (!_isAndroid()) {
      throw UnsupportedError(
        'Installed applications are available on Android.',
      );
    }

    final result = await _channel.invokeListMethod<Object?>(
      'listInstalledUserApps',
    );
    if (result == null) {
      throw const FormatException('Android returned no application list.');
    }

    final apps = <InstalledApp>[];
    for (final entry in result) {
      if (entry is! Map<Object?, Object?>) {
        throw const FormatException('Android returned invalid app metadata.');
      }
      final name = entry['appName'];
      final packageName = entry['packageName'];
      final rawPaths = entry['apkPaths'];
      final versionName = entry['versionName'];
      final rawIcon = entry['icon'];
      if (name is! String ||
          packageName is! String ||
          rawPaths is! List<Object?> ||
          (versionName != null && versionName is! String) ||
          (rawIcon != null && rawIcon is! Uint8List)) {
        throw const FormatException(
          'Android returned incomplete app metadata.',
        );
      }

      final apkPaths = rawPaths.whereType<String>().toList(growable: false);
      if (apkPaths.isEmpty || apkPaths.length != rawPaths.length) {
        throw const FormatException('Android returned invalid APK paths.');
      }
      final apkSizes = <int>[];
      for (final path in apkPaths) {
        final file = File(path);
        if (!await file.exists()) {
          throw FileSystemException('APK file is no longer available.', path);
        }
        apkSizes.add(await file.length());
      }
      apps.add(
        InstalledApp(
          name: name,
          packageName: packageName,
          versionName: versionName as String?,
          apkPaths: apkPaths,
          apkSizes: apkSizes,
          iconBytes: rawIcon as Uint8List?,
        ),
      );
    }

    apps.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return List.unmodifiable(apps);
  }

  Future<List<TransferFileSource>> createTransferSources(
    Iterable<InstalledApp> apps,
  ) async {
    final sources = <TransferFileSource>[];
    for (final app in apps) {
      for (final apkPath in app.apkPaths) {
        final file = File(apkPath);
        if (!await file.exists()) {
          throw FileSystemException(
            'تعذّر الوصول إلى ملف تثبيت التطبيق.',
            apkPath,
          );
        }
        final name = _apkTransferName(app, apkPath);
        sources.add(
          TransferFileSource(
            name: name,
            size: await file.length(),
            openRead: file.openRead,
          ),
        );
      }
    }
    return List.unmodifiable(sources);
  }

  String _apkTransferName(InstalledApp app, String path) {
    final apkName = path.split(Platform.pathSeparator).last;
    if (apkName == 'base.apk') return '${app.packageName}.apk';
    final splitName = apkName.replaceFirst(
      RegExp(r'\.apk$', caseSensitive: false),
      '',
    );
    return '${app.packageName}_$splitName.apk';
  }
}
