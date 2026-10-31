import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/accent_color_picker.dart';
import '../../../app/theme/app_theme.dart';
import '../../connection/data/local_hotspot_controller.dart';
import '../../devices/data/device_discovery_controller.dart';
import '../../transfer/data/local_transfer_service.dart';
import '../../transfer/domain/transfer_file_source.dart';
import 'file_selection_screen.dart';
import 'transfer_flow_screens.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
    required this.onSetPrimaryColor,
  });

  final bool isDarkMode;
  final Future<void> Function() onToggleTheme;
  final Future<void> Function(Color color) onSetPrimaryColor;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final LocalHotspotController _hotspot = LocalHotspotController();
  final DeviceDiscoveryController _discovery = DeviceDiscoveryController();
  final LocalTransferService _transfers = LocalTransferService();

  @override
  void initState() {
    super.initState();
    unawaited(_startLocalServices());
  }

  Future<void> _startLocalServices() async {
    await _transfers.start();
    if (mounted && _transfers.isRunning) {
      await _discovery.start();
    }
  }

  Future<void> _refreshLocalNetwork() async {
    await _transfers.start();
    if (mounted && _transfers.isRunning) {
      await _transfers.refreshLocalAddresses();
      await _discovery.restart();
    }
  }

  @override
  void dispose() {
    _hotspot.dispose();
    _discovery.dispose();
    _transfers.dispose();
    super.dispose();
  }

  Future<void> _toggleHotspot() async {
    try {
      if (_hotspot.isActive) {
        await _hotspot.stop();
      } else {
        await _hotspot.start();
      }
      if (mounted && _transfers.isRunning) {
        await _transfers.refreshLocalAddresses();
        await _discovery.restart();
      }
    } catch (error) {
      if (mounted) _showMessage(_hotspot.errorMessage ?? error.toString());
    }
  }

  Future<void> _copyHotspotCredentials() async {
    final ssid = _hotspot.ssid;
    if (ssid == null) return;
    final passphrase = _hotspot.passphrase;
    final credentials = passphrase == null
        ? 'اسم الشبكة: $ssid'
        : 'اسم الشبكة: $ssid\nكلمة المرور: $passphrase';
    try {
      await Clipboard.setData(ClipboardData(text: credentials));
      if (mounted) _showMessage('تم نسخ بيانات نقطة الاتصال.');
    } catch (error) {
      if (mounted) _showMessage('تعذّر نسخ بيانات الاتصال: $error');
    }
  }

  Future<void> _copyLocalAddress(String address) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: '$address:${_transfers.listeningPort}'),
      );
      if (mounted) _showMessage('تم نسخ عنوان الجهاز.');
    } catch (error) {
      if (mounted) _showMessage('تعذّر نسخ عنوان IP: $error');
    }
  }

  Future<void> _openSendFlow({List<TransferFileSource>? droppedSources}) async {
    if (!_transfers.isRunning) {
      _showMessage(
        _transfers.serverError ?? 'خادم الاستقبال المحلي غير جاهز.',
      );
      return;
    }

    final sources = droppedSources ??
        await Navigator.of(context).push<List<TransferFileSource>>(
          MaterialPageRoute<List<TransferFileSource>>(
            builder: (_) => const FileSelectionScreen(),
          ),
        );
    if (!mounted || sources == null || sources.isEmpty) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionScreen(
          sources: sources,
          discovery: _discovery,
          transfers: _transfers,
          hotspot: _hotspot,
          onRefresh: _refreshLocalNetwork,
          onToggleHotspot: _toggleHotspot,
          onCopyHotspot: _copyHotspotCredentials,
        ),
      ),
    );
  }

  Future<void> _sendDroppedItems(List<DropItem> items) async {
    try {
      final sources = <TransferFileSource>[];
      for (final item in items) {
        if (item is! DropItemFile) {
          throw StateError('سحب المجلدات غير مدعوم؛ اسحب الملفات فقط.');
        }
        sources.add(
          TransferFileSource(
            name: item.name,
            size: await item.length(),
            openRead: item.openRead,
          ),
        );
      }
      if (mounted) await _openSendFlow(droppedSources: sources);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _openReceiveFlow() async {
    if (!_transfers.isRunning) {
      _showMessage(
        _transfers.serverError ?? 'خادم الاستقبال المحلي غير جاهز.',
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReceiveWaitingScreen(
          transfers: _transfers,
          hotspot: _hotspot,
          onRefresh: _refreshLocalNetwork,
          onToggleHotspot: _toggleHotspot,
          onCopyHotspot: _copyHotspotCredentials,
          onCopyAddress: _copyLocalAddress,
        ),
      ),
    );
  }

  Future<void> _toggleTheme() async {
    try {
      await widget.onToggleTheme();
    } catch (error) {
      if (mounted) _showMessage('تعذّر حفظ إعداد المظهر: $error');
    }
  }

  Future<void> _chooseAccentColor() async {
    final color = await showAccentColorPicker(
      context,
      selectedColor: AppColors.primaryColor,
    );
    if (color == null) return;
    try {
      await widget.onSetPrimaryColor(color);
    } catch (error) {
      if (mounted) _showMessage('تعذّر حفظ لون التطبيق: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 540;
            final horizontalPadding = constraints.maxWidth < 380 ? 16.0 : 24.0;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    compact ? 8 : 18,
                    horizontalPadding,
                    compact ? 12 : 22,
                  ),
                  child: Column(
                    children: [
                      _DashboardTopBar(
                        isDarkMode: widget.isDarkMode,
                        onToggleTheme: () => unawaited(_toggleTheme()),
                        onChooseAccentColor: () =>
                            unawaited(_chooseAccentColor()),
                      ),
                      SizedBox(height: compact ? 12 : 24),
                      _DashboardHeading(compact: compact),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: compact ? 150 : 220,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: DropTarget(
                                    onDragDone: (details) =>
                                        unawaited(_sendDroppedItems(details.files)),
                                    child: _DashboardAction(
                                      icon: Icons.send_rounded,
                                      title: 'إرسال',
                                      subtitle: 'اختر ملفات وأرسلها',
                                      primary: true,
                                      onTap: () => unawaited(_openSendFlow()),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _DashboardAction(
                                    icon: Icons.move_to_inbox_rounded,
                                    title: 'استقبال',
                                    subtitle: 'انتظر الملفات الواردة',
                                    primary: false,
                                    onTap: () => unawaited(_openReceiveFlow()),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: Listenable.merge([_transfers, _hotspot]),
                        builder: (context, _) => _ConnectionSummary(
                          addresses: _transfers.localAddresses,
                          port: _transfers.listeningPort,
                          isRunning: _transfers.isRunning,
                          isHotspotActive: _hotspot.isActive,
                          errorMessage: _transfers.serverError,
                          onRefresh: () => unawaited(_refreshLocalNetwork()),
                          onCopyAddress: (address) =>
                              unawaited(_copyLocalAddress(address)),
                        ),
                      ),
                      if (compact) const SizedBox(height: 4),
                      if (!compact) const SizedBox(height: 8),
                      Text(
                        'اتصلوا بنفس شبكة Wi-Fi لنقل الملفات مباشرةً.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _DashboardTopBar extends StatelessWidget {
  const _DashboardTopBar({
    required this.isDarkMode,
    required this.onToggleTheme,
    required this.onChooseAccentColor,
  });

  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final VoidCallback onChooseAccentColor;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.swap_horiz_rounded, color: Theme.of(context).colorScheme.onPrimary),
      ),
      const SizedBox(width: 10),
      Text('وصلة', style: Theme.of(context).textTheme.titleLarge),
      const Spacer(),
      IconButton(
        tooltip: 'تخصيص لون التطبيق',
        onPressed: onChooseAccentColor,
        icon: const Icon(Icons.palette_outlined),
      ),
      TextButton.icon(
        onPressed: onToggleTheme,
        icon: Icon(isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
        label: Text(isDarkMode ? 'فاتح' : 'داكن'),
      ),
    ],
  );
}

class _DashboardHeading extends StatelessWidget {
  const _DashboardHeading({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        'مشاركة سهلة، مباشرة وآمنة',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: compact ? 22 : 27,
        ),
      ),
      if (!compact) ...[
        const SizedBox(height: 5),
        Text(
          'انقل ملفاتك بين أجهزتك دون رفعها إلى السحابة.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ],
  );
}

class _DashboardAction extends StatelessWidget {
  const _DashboardAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primary,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = primary ? colors.primary : colors.secondaryContainer;
    final foreground = primary ? colors.onPrimary : colors.onSecondaryContainer;
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: primary ? Colors.transparent : colors.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, size: 30, color: foreground),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: foreground,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: foreground.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionSummary extends StatelessWidget {
  const _ConnectionSummary({
    required this.addresses,
    required this.port,
    required this.isRunning,
    required this.isHotspotActive,
    required this.errorMessage,
    required this.onRefresh,
    required this.onCopyAddress,
  });

  final List<String> addresses;
  final int port;
  final bool isRunning;
  final bool isHotspotActive;
  final String? errorMessage;
  final VoidCallback onRefresh;
  final ValueChanged<String> onCopyAddress;

  @override
  Widget build(BuildContext context) {
    final ipv4Addresses = addresses.where((item) => !item.contains(':'));
    final address = ipv4Addresses.isNotEmpty
        ? ipv4Addresses.first
        : addresses.isNotEmpty
        ? addresses.first
        : null;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            isRunning ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            color: isRunning ? colorScheme.primary : colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isHotspotActive ? 'نقطة الاتصال جاهزة' : 'اتصال الشبكة',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  errorMessage ??
                      (address == null
                          ? 'جارٍ تحديد عنوان IP المحلي...'
                          : 'IP: ${_formatAddress(address, port)}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (address != null)
            IconButton(
              tooltip: 'نسخ عنوان IP والمنفذ',
              onPressed: () => onCopyAddress(address),
              icon: const Icon(Icons.copy_rounded),
            ),
          IconButton(
            tooltip: 'تحديث الاتصال',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

String _formatAddress(String address, int port) =>
    address.contains(':') ? '[$address]:$port' : '$address:$port';
