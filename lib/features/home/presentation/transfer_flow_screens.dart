import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../connection/data/local_hotspot_controller.dart';
import '../../devices/data/device_discovery_controller.dart';
import '../../devices/domain/discovered_device.dart';
import '../../transfer/data/local_transfer_service.dart';
import '../../transfer/domain/transfer_file_source.dart';
import '../../transfer/domain/transfer_snapshot.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.sources,
    required this.discovery,
    required this.transfers,
    required this.hotspot,
    required this.onRefresh,
    required this.onToggleHotspot,
    required this.onCopyHotspot,
  });

  final List<TransferFileSource> sources;
  final DeviceDiscoveryController discovery;
  final LocalTransferService transfers;
  final LocalHotspotController hotspot;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleHotspot;
  final Future<void> Function() onCopyHotspot;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _manualAddressController = TextEditingController();
  DiscoveredDevice? _selectedDevice;

  @override
  void dispose() {
    _manualAddressController.dispose();
    super.dispose();
  }

  Future<void> _addManualDevice() async {
    _manualAddressController.clear();
    final controller = _manualAddressController;
    final device = await showDialog<DiscoveredDevice>(
      context: context,
      builder: (dialogContext) {
        String? errorMessage;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submitAddress() {
              final address = InternetAddress.tryParse(controller.text.trim());
              if (address == null) {
                setDialogState(
                  () => errorMessage = 'أدخل عنوان IPv4 أو IPv6 صالحًا.',
                );
                return;
              }
              Navigator.pop(
                dialogContext,
                DiscoveredDevice(
                  id: 'manual-${address.address}',
                  platform: 'unknown',
                  name: address.address,
                  addresses: [address.address],
                  port: LocalTransferService.port,
                  isResolved: true,
                ),
              );
            }

            return AlertDialog(
              title: const Text('الاتصال بعنوان IP'),
              content: Directionality(
                textDirection: TextDirection.ltr,
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'مثال: 192.168.1.25',
                    errorText: errorMessage,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (errorMessage != null) {
                      setDialogState(() => errorMessage = null);
                    }
                  },
                  onSubmitted: (_) => submitAddress(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: submitAddress,
                  child: const Text('متابعة'),
                ),
              ],
            );
          },
        );
      },
    );
    if (device != null && mounted) {
      setState(() => _selectedDevice = device);
    }
  }

  Future<void> _startTransfer() async {
    final device = _selectedDevice;
    if (device == null || !device.canConnect) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransferProgressScreen(
          sources: widget.sources,
          device: device,
          transfers: widget.transfers,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('الاتصال بالجهاز'),
        actions: [
          IconButton(
            tooltip: 'إدخال عنوان IP',
            onPressed: _addManualDevice,
            icon: const Icon(Icons.edit_location_alt_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.discovery, widget.transfers]),
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              _FlowHeading(
                icon: Icons.near_me_rounded,
                title: 'اختر الجهاز المستلم',
                subtitle:
                    '${widget.sources.length} ملف${widget.sources.length == 1 ? '' : 'ات'} جاهز للإرسال',
              ),
              const SizedBox(height: 18),
              _LocalNetworkCard(
                addresses: widget.transfers.localAddresses,
                port: widget.transfers.listeningPort,
                hotspot: widget.hotspot,
                hotspotSupported: Platform.isAndroid,
                onRefresh: widget.onRefresh,
                onToggleHotspot: widget.onToggleHotspot,
                onCopyHotspot: widget.onCopyHotspot,
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(
                    'الأجهزة القريبة',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.discovery.isSearching
                        ? null
                        : () => widget.discovery.restart(),
                    tooltip: 'تحديث البحث',
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              if (widget.discovery.errorMessage != null)
                _InlineMessage(
                  icon: Icons.wifi_off_rounded,
                  message: widget.discovery.errorMessage!,
                  isError: true,
                ),
              if (widget.discovery.devices.isEmpty)
                _EmptyDevices(searching: widget.discovery.isSearching)
              else
                ...widget.discovery.devices.map(
                  (device) => _DeviceChoice(
                    device: device,
                    selected: _selectedDevice?.id == device.id,
                    onTap: device.canConnect
                        ? () => setState(() => _selectedDevice = device)
                        : null,
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _addManualDevice,
                icon: const Icon(Icons.edit_location_alt_rounded),
                label: const Text('الاتصال بعنوان IP'),
              ),
              if (_selectedDevice != null) ...[
                const SizedBox(height: 8),
                _InlineMessage(
                  icon: Icons.check_circle_outline_rounded,
                  message: 'الجهاز المحدد: ${_deviceName(_selectedDevice!)}',
                  isError: false,
                ),
              ],
              if (_selectedDevice != null) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _selectedDevice!.canConnect
                      ? _startTransfer
                      : null,
                  icon: const Icon(Icons.send_rounded),
                  label: Text('بدء الإرسال · ${widget.sources.length}'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class TransferProgressScreen extends StatefulWidget {
  const TransferProgressScreen({
    super.key,
    required this.sources,
    required this.device,
    required this.transfers,
  });

  final List<TransferFileSource> sources;
  final DiscoveredDevice device;
  final LocalTransferService transfers;

  @override
  State<TransferProgressScreen> createState() => _TransferProgressScreenState();
}

class _TransferProgressScreenState extends State<TransferProgressScreen> {
  late final Set<String> _previousIds;
  String? _errorMessage;
  bool _finished = false;

  List<TransferSnapshot> _currentTransfers() => widget.transfers.transfers
      .where((transfer) => !_previousIds.contains(transfer.id))
      .toList();

  @override
  void initState() {
    super.initState();
    _previousIds = widget.transfers.transfers
        .map((transfer) => transfer.id)
        .toSet();
    _send();
  }

  Future<void> _send() async {
    try {
      await widget.transfers.sendSources(widget.sources, widget.device);
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      if (mounted) setState(() => _finished = true);
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await widget.transfers.cancelTransfer(id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر إلغاء النقل: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('تقدم الإرسال')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.transfers,
          builder: (context, _) {
            final transfers = _currentTransfers();
            final allCompleted =
                transfers.isNotEmpty &&
                transfers.every(
                  (transfer) => transfer.status == TransferStatus.completed,
                );
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _FlowHeading(
                  icon: allCompleted
                      ? Icons.check_circle_rounded
                      : Icons.swap_horiz_rounded,
                  title: allCompleted ? 'اكتمل الإرسال' : 'جارٍ الإرسال',
                  subtitle: 'إلى ${_deviceName(widget.device)}',
                ),
                if (_errorMessage != null)
                  _InlineMessage(
                    icon: Icons.error_outline_rounded,
                    message: _errorMessage!,
                    isError: true,
                  ),
                const SizedBox(height: 16),
                if (transfers.isEmpty && !_finished)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                for (final transfer in transfers)
                  _ProgressTransferCard(
                    transfer: transfer,
                    onCancel: transfer.canCancel
                        ? () => _cancel(transfer.id)
                        : null,
                  ),
                if (_finished && transfers.isEmpty)
                  const _InlineMessage(
                    icon: Icons.info_outline_rounded,
                    message:
                        'لم يبدأ أي نقل. ارجع للشاشة السابقة وحاول مجددًا.',
                    isError: false,
                  ),
                if (_finished || allCompleted) ...[
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('العودة للأجهزة'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}

class ReceiveWaitingScreen extends StatelessWidget {
  const ReceiveWaitingScreen({
    super.key,
    required this.transfers,
    required this.hotspot,
    required this.onRefresh,
    required this.onToggleHotspot,
    required this.onCopyHotspot,
    required this.onCopyAddress,
  });

  final LocalTransferService transfers;
  final LocalHotspotController hotspot;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleHotspot;
  final Future<void> Function() onCopyHotspot;
  final ValueChanged<String> onCopyAddress;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('استقبال الملفات')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: transfers,
          builder: (context, _) {
            final incoming = transfers.transfers
                .where(
                  (transfer) =>
                      transfer.direction == TransferDirection.incoming,
                )
                .toList();
            final active = incoming.any((transfer) => transfer.isActive);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                _FlowHeading(
                  icon: active
                      ? Icons.downloading_rounded
                      : Icons.wifi_tethering_rounded,
                  title: active ? 'استقبال ملف' : 'بانتظار جهاز قريب',
                  subtitle: active
                      ? 'تابع النقل أو أجب عن طلب الاستقبال أدناه.'
                      : 'اتصلوا بنفس الشبكة المحلية لإرسال ملف إليك.',
                ),
                const SizedBox(height: 18),
                _LocalNetworkCard(
                  addresses: transfers.localAddresses,
                  port: transfers.listeningPort,
                  hotspot: hotspot,
                  hotspotSupported: Platform.isAndroid,
                  onRefresh: onRefresh,
                  onToggleHotspot: onToggleHotspot,
                  onCopyHotspot: onCopyHotspot,
                  onCopyAddress: onCopyAddress,
                ),
                const SizedBox(height: 20),
                Text(
                  'طلبات وعمليات الاستقبال',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (incoming.isEmpty)
                  const _InlineMessage(
                    icon: Icons.inbox_outlined,
                    message: 'ستظهر طلبات النقل هنا فور وصولها.',
                    isError: false,
                  )
                else
                  for (final transfer in incoming)
                    _IncomingTransferCard(
                      transfer: transfer,
                      onAccept: () => transfers.accept(transfer.id),
                      onReject: () => transfers.reject(transfer.id),
                      onCancel: () => transfers.cancelTransfer(transfer.id),
                      onRemove: () => transfers.removeTransfer(transfer.id),
                    ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _LocalNetworkCard extends StatelessWidget {
  const _LocalNetworkCard({
    required this.addresses,
    required this.port,
    required this.hotspot,
    required this.hotspotSupported,
    required this.onRefresh,
    required this.onToggleHotspot,
    required this.onCopyHotspot,
    this.onCopyAddress,
  });

  final List<String> addresses;
  final int port;
  final LocalHotspotController hotspot;
  final bool hotspotSupported;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleHotspot;
  final Future<void> Function() onCopyHotspot;
  final ValueChanged<String>? onCopyAddress;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.lan_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'عنوان هذا الجهاز',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'تحديث العناوين',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (addresses.isEmpty)
          const Text('لم يظهر عنوان شبكة بعد؛ تحقق من اتصال Wi-Fi.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final address in addresses)
                ActionChip(
                  avatar: const Icon(Icons.copy_rounded, size: 15),
                  label: Text(_formatAddress(address, port)),
                  onPressed: () async {
                    if (onCopyAddress != null) {
                      onCopyAddress!(address);
                    } else {
                      await Clipboard.setData(
                        ClipboardData(text: _formatAddress(address, port)),
                      );
                    }
                  },
                ),
            ],
          ),
        const Divider(height: 24),
        AnimatedBuilder(
          animation: hotspot,
          builder: (context, _) => Row(
            children: [
              Icon(
                hotspot.isActive
                    ? Icons.wifi_tethering_rounded
                    : Icons.wifi_rounded,
                color: hotspot.isActive
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hotspot.isActive
                      ? 'نقطة الاتصال نشطة${hotspot.ssid == null ? '' : ' · ${hotspot.ssid}'}'
                      : hotspotSupported
                      ? 'نقطة الاتصال غير نشطة'
                      : 'أنشئ نقطة الاتصال من إعدادات الجهاز',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: !hotspotSupported || hotspot.isBusy
                    ? null
                    : onToggleHotspot,
                child: Text(
                  hotspot.isActive
                      ? 'إيقاف'
                      : hotspotSupported
                      ? 'تشغيل'
                      : 'غير متاح',
                ),
              ),
              if (hotspot.isActive)
                IconButton(
                  tooltip: 'نسخ بيانات الشبكة',
                  onPressed: onCopyHotspot,
                  icon: const Icon(Icons.copy_all_rounded),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FlowHeading extends StatelessWidget {
  const _FlowHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.8, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutBack,
        builder: (context, value, child) =>
            Transform.scale(scale: value, child: child),
        child: CircleAvatar(
          radius: 25,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.primary,
          child: Icon(icon),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    ],
  );
}

class _DeviceChoice extends StatelessWidget {
  const _DeviceChoice({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final DiscoveredDevice device;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
    child: ListTile(
      leading: Icon(
        device.canConnect ? Icons.devices_rounded : Icons.hourglass_top_rounded,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(_deviceName(device)),
      subtitle: Text(
        device.canConnect
            ? '${device.platform} · ${device.addresses.isEmpty ? device.hostname ?? '' : device.addresses.first}'
            : 'جارٍ تحديد اسم الجهاز...',
      ),
      trailing: selected
          ? Icon(
              Icons.check_circle_rounded,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onTap: onTap,
    ),
  );
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        if (searching)
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(Icons.devices_other_rounded, size: 32, color: AppColors.muted),
        const SizedBox(height: 10),
        Text(
          searching
              ? 'جارٍ البحث عن أجهزة قريبة...'
              : 'لا توجد أجهزة قريبة حاليًا.',
        ),
      ],
    ),
  );
}

class _ProgressTransferCard extends StatelessWidget {
  const _ProgressTransferCard({required this.transfer, required this.onCancel});

  final TransferSnapshot transfer;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, color: primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onCancel != null)
                  IconButton(
                    onPressed: onCancel,
                    tooltip: 'إلغاء النقل',
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: transfer.status == TransferStatus.transferring
                  ? transfer.progress
                  : transfer.status == TransferStatus.completed
                  ? 1
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text(_transferStatus(transfer))),
                if (transfer.status == TransferStatus.transferring)
                  Text('${(transfer.progress * 100).round()}%'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingTransferCard extends StatelessWidget {
  const _IncomingTransferCard({
    required this.transfer,
    required this.onAccept,
    required this.onReject,
    required this.onCancel,
    required this.onRemove,
  });

  final TransferSnapshot transfer;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final Future<void> Function() onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 8),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            transfer.fileName,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '${transfer.peerName} · ${_formatSize(transfer.totalBytes)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (transfer.needsApproval)
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('قبول'),
                ),
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('رفض'),
                ),
              ],
            )
          else if (transfer.status == TransferStatus.transferring)
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(value: transfer.progress),
                ),
                const SizedBox(width: 12),
                Text('${(transfer.progress * 100).round()}%'),
                IconButton(
                  onPressed: onCancel,
                  tooltip: 'إلغاء النقل',
                  icon: const Icon(Icons.cancel_outlined),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(child: Text(_transferStatus(transfer))),
                IconButton(
                  onPressed: onRemove,
                  tooltip: 'إزالة من السجل',
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({
    required this.icon,
    required this.message,
    required this.isError,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Icon(
          icon,
          color: isError
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

String _deviceName(DiscoveredDevice device) =>
    device.name.isNotEmpty ? device.name : device.platform;

String _formatAddress(String address, int port) =>
    address.contains(':') ? '[$address]:$port' : '$address:$port';

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(1)} ${units[unit]}';
}

String _transferStatus(TransferSnapshot transfer) => switch (transfer.status) {
  TransferStatus.requesting => 'جارٍ طلب الموافقة من المستلم',
  TransferStatus.awaitingApproval => 'بانتظار موافقة المستلم',
  TransferStatus.waitingForUpload => 'تمت الموافقة · جارٍ التجهيز',
  TransferStatus.transferring =>
    '${_formatSize(transfer.transferredBytes)} / ${_formatSize(transfer.totalBytes)}',
  TransferStatus.completed => 'اكتمل النقل',
  TransferStatus.rejected => 'تم رفض الاستقبال',
  TransferStatus.failed => transfer.errorMessage ?? 'فشل النقل',
  TransferStatus.cancelled => 'تم إلغاء النقل',
};
