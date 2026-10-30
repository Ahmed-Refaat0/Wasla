import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/apps/data/installed_apps_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wasla/test_installed_apps');

  test(
    'loads installed app metadata and streams base and split APKs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wasla-installed-app-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      const packageName = 'com.example.share';
      final baseApk = File(
        '${directory.path}${Platform.pathSeparator}base.apk',
      );
      final splitApk = File(
        '${directory.path}${Platform.pathSeparator}split_config.arm64_v8a.apk',
      );
      await baseApk.writeAsBytes([1, 2, 3]);
      await splitApk.writeAsBytes([4, 5]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'listInstalledUserApps');
            return [
              {
                'appName': 'Share App',
                'packageName': packageName,
                'versionName': '1.0',
                'apkPaths': [baseApk.path, splitApk.path],
                'icon': Uint8List.fromList([1, 2, 3]),
              },
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final service = InstalledAppsService(
        methodChannel: channel,
        isAndroid: () => true,
      );
      final apps = await service.listUserApps();
      expect(apps, hasLength(1));
      expect(apps.single.packageName, packageName);
      expect(apps.single.apkPaths, [baseApk.path, splitApk.path]);

      final sources = await service.createTransferSources(apps);
      expect(sources.map((source) => source.name), [
        '$packageName.apk',
        '${packageName}_split_config.arm64_v8a.apk',
      ]);
      expect(sources.map((source) => source.size), [3, 2]);
      expect(
        await sources.first
            .openRead()
            .expand((chunk) => chunk.toList())
            .toList(),
        [1, 2, 3],
      );
    },
  );
}
