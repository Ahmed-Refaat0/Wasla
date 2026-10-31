import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/connection/data/local_hotspot_controller.dart';
import 'package:wasla/features/devices/data/device_discovery_controller.dart';
import 'package:wasla/features/home/presentation/transfer_flow_screens.dart';
import 'package:wasla/features/transfer/data/local_transfer_service.dart';
import 'package:wasla/features/transfer/domain/transfer_file_source.dart';

void main() {
  testWidgets('connects to a device using a manually entered IP address', (
    tester,
  ) async {
    final discovery = DeviceDiscoveryController();
    final transfers = LocalTransferService(serverPort: 0);
    final hotspot = LocalHotspotController(isAndroid: () => false);
    addTearDown(discovery.dispose);
    addTearDown(transfers.dispose);
    addTearDown(hotspot.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionScreen(
          sources: [
            TransferFileSource(
              name: 'photo.jpg',
              size: 12,
              openRead: () => Stream.value([1, 2, 3]),
            ),
          ],
          discovery: discovery,
          transfers: transfers,
          hotspot: hotspot,
          onRefresh: () async {},
          onToggleHotspot: () async {},
          onCopyHotspot: () async {},
        ),
      ),
    );

    expect(find.text('الاتصال بعنوان IP'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-an-ip');
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    expect(find.text('أدخل عنوان IPv4 أو IPv6 صالحًا.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '192.168.1.25');
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();

    expect(find.text('الجهاز المحدد: 192.168.1.25'), findsOneWidget);
    final startButton = find.text('بدء الإرسال · 1');
    await tester.scrollUntilVisible(
      startButton,
      250,
      scrollable: find.byType(Scrollable),
    );
    expect(startButton, findsOneWidget);
  });
}
