import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/connection/data/local_hotspot_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wasla/test_local_hotspot');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts and stops a local hotspot using native credentials', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return {'ssid': 'Wasla-test', 'passphrase': 'test-pass'};
          }
          if (call.method == 'stop') return null;
          throw MissingPluginException();
        });
    final controller = LocalHotspotController(
      channel: channel,
      isAndroid: () => true,
    );
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.status, LocalHotspotStatus.active);
    expect(controller.ssid, 'Wasla-test');
    expect(controller.passphrase, 'test-pass');

    await controller.stop();
    expect(controller.status, LocalHotspotStatus.idle);
    expect(controller.ssid, isNull);
    expect(controller.passphrase, isNull);
  });

  test('reports native permission failures instead of hiding them', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'permission_denied',
            message: 'Nearby devices permission was denied.',
          );
        });
    final controller = LocalHotspotController(
      channel: channel,
      isAndroid: () => true,
    );
    addTearDown(controller.dispose);

    await expectLater(controller.start(), throwsA(isA<PlatformException>()));
    expect(controller.status, LocalHotspotStatus.error);
    expect(controller.errorMessage, contains('permission_denied'));
  });

  test('does not request Android hotspot controls on Windows', () async {
    var methodWasCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodWasCalled = true;
          return null;
        });
    final controller = LocalHotspotController(
      channel: channel,
      isAndroid: () => false,
    );
    addTearDown(controller.dispose);

    await expectLater(controller.start(), throwsA(isA<UnsupportedError>()));
    expect(methodWasCalled, isFalse);
    expect(controller.status, LocalHotspotStatus.idle);
  });
}
