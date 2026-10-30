import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/devices/domain/discovered_device.dart';
import 'package:wasla/features/transfer/data/local_transfer_service.dart';
import 'package:wasla/features/transfer/domain/transfer_file_source.dart';
import 'package:wasla/features/transfer/domain/transfer_snapshot.dart';

void main() {
  test('streams a file after receiver approval', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'wasla-transfer-test-',
    );
    addTearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    final receivedDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}received',
    );
    final sender = LocalTransferService(serverPort: 0);
    final receiver = LocalTransferService(
      serverPort: 0,
      downloadsDirectoryProvider: () async => receivedDirectory,
      documentsDirectoryProvider: () async => receivedDirectory,
    );
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    await sender.start();
    await receiver.start();

    expect(sender.isRunning, isTrue);
    expect(receiver.isRunning, isTrue);

    final source = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}sample.txt',
    );
    await source.writeAsString('Wasla streams this file.');

    final target = DiscoveredDevice(
      id: 'test-device',
      platform: 'test',
      addresses: const [],
      port: receiver.listeningPort,
      isResolved: false,
      hostname: '127.0.0.1',
    );

    final sendFuture = sender.sendFiles([source], target);
    await _waitUntil(
      () => receiver.transfers.any((transfer) => transfer.needsApproval),
    );

    final incoming = receiver.transfers.single;
    expect(incoming.fileName, 'sample.txt');
    expect(incoming.totalBytes, await source.length());

    receiver.accept(incoming.id);
    await sendFuture.timeout(const Duration(seconds: 10));

    final completedIncoming = receiver.transfers.singleWhere(
      (transfer) => transfer.direction == TransferDirection.incoming,
    );
    final completedOutgoing = sender.transfers.single;
    expect(completedIncoming.status, TransferStatus.completed);
    expect(completedOutgoing.status, TransferStatus.completed);
    expect(completedIncoming.progress, 1);
    expect(completedOutgoing.progress, 1);
    expect(completedIncoming.savedPath, isNotNull);
    expect(
      await File(completedIncoming.savedPath!).readAsString(),
      'Wasla streams this file.',
    );
  });

  test('reports intermediate progress while streaming a large file', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'wasla-progress-test-',
    );
    addTearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    final receivedDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}received',
    );
    final sender = LocalTransferService(serverPort: 0);
    final receiver = LocalTransferService(
      serverPort: 0,
      downloadsDirectoryProvider: () async => receivedDirectory,
      documentsDirectoryProvider: () async => receivedDirectory,
    );
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    await sender.start();
    await receiver.start();

    const chunkSize = 16 * 1024;
    const chunkCount = 32;
    const totalBytes = chunkSize * chunkCount;
    var sawIntermediateProgress = false;
    var sawReceivedIntermediateProgress = false;
    sender.addListener(() {
      for (final transfer in sender.transfers) {
        if (transfer.status == TransferStatus.transferring &&
            transfer.transferredBytes > 0 &&
            transfer.transferredBytes < transfer.totalBytes) {
          sawIntermediateProgress = true;
        }
      }
    });
    receiver.addListener(() {
      for (final transfer in receiver.transfers) {
        if (transfer.status == TransferStatus.transferring &&
            transfer.transferredBytes > 0 &&
            transfer.transferredBytes < transfer.totalBytes) {
          sawReceivedIntermediateProgress = true;
        }
      }
    });

    final target = DiscoveredDevice(
      id: 'progress-device',
      platform: 'test',
      addresses: const ['127.0.0.1'],
      port: receiver.listeningPort,
      isResolved: true,
    );
    final source = TransferFileSource(
      name: 'large.bin',
      size: totalBytes,
      openRead: () => Stream<List<int>>.periodic(
        const Duration(milliseconds: 20),
        (_) => List<int>.filled(chunkSize, 7, growable: false),
      ).take(chunkCount),
    );

    final sendFuture = sender.sendSources([source], target);
    await _waitUntil(
      () => receiver.transfers.any((transfer) => transfer.needsApproval),
    );
    receiver.accept(receiver.transfers.single.id);
    await sendFuture.timeout(const Duration(seconds: 10));

    final outgoing = sender.transfers.single;
    expect(outgoing.status, TransferStatus.completed);
    expect(outgoing.transferredBytes, totalBytes);
    expect(outgoing.bytesPerSecond, greaterThan(0));
    expect(sawIntermediateProgress, isTrue);
    expect(sawReceivedIntermediateProgress, isTrue);
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the transfer condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
