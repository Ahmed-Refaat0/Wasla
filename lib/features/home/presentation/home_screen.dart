import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../connection/data/local_hotspot_controller.dart';
import '../../devices/data/device_discovery_controller.dart';
import '../../devices/domain/discovered_device.dart';
import '../../transfer/data/local_transfer_service.dart';
import '../../transfer/domain/transfer_file_source.dart';
import 'file_selection_screen.dart';
import '../../transfer/domain/transfer_snapshot.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  final bool isDarkMode;
  final Future<void> Function() onToggleTheme;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _HomeMode { send, receive }

class _HomeScreenState extends State<HomeScreen> {
  final LocalHotspotController _hotspot = LocalHotspotController();
  final DeviceDiscoveryController _discovery = DeviceDiscoveryController();
  final LocalTransferService _transfers = LocalTransferService();
  final TextEditingController _manualAddressController =
      TextEditingController();
  _HomeMode _mode = _HomeMode.send;

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

  Future<void> _retryLocalServices() async {
    await _transfers.start();
    if (mounted && _transfers.isRunning) {
      await _transfers.refreshLocalAddresses();
      await _discovery.restart();
    }
  }

  @override
  void dispose() {
    _manualAddressController.dispose();
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
      await Clipboard.setData(ClipboardData(text: address));
      if (mounted) _showMessage('تم نسخ عنوان IP.');
    } catch (error) {
      if (mounted) _showMessage('تعذّر نسخ عنوان IP: $error');
    }
  }

  Future<void> _pickFilesAndSend({DiscoveredDevice? device}) async {
    try {
      if (!_transfers.isRunning) {
        throw StateError('خادم الاستقبال المحلي غير جاهز.');
      }
      final target = device ?? await _chooseDevice();
      if (target == null || !mounted) return;

      final sources = await Navigator.of(context)
          .push<List<TransferFileSource>>(
            MaterialPageRoute<List<TransferFileSource>>(
              builder: (_) => const FileSelectionScreen(),
            ),
          );
      if (sources == null || sources.isEmpty || !mounted) return;
      await _sendSources(sources, device: target);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _sendDroppedItems(List<DropItem> items) async {
    try {
      final target = await _chooseDevice();
      if (target == null || !mounted) return;
      final sources = <TransferFileSource>[];
      for (final item in items) {
        if (item is! DropItemFile) {
          throw StateError('سحب المجلدات غير مدعوم؛ اسحب الملفات فقط.');
        }
        final size = await item.length();
        sources.add(
          TransferFileSource(
            name: item.name,
            size: size,
            openRead: item.openRead,
          ),
        );
      }
      await _sendSources(sources, device: target);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _sendSources(
    List<TransferFileSource> sources, {
    DiscoveredDevice? device,
  }) async {
    try {
      if (sources.isEmpty) return;
      if (!_transfers.isRunning) {
        throw StateError('خادم الاستقبال المحلي غير جاهز.');
      }

      final target = device ?? await _chooseDevice();
      if (target == null || !mounted) return;
      await _transfers.sendSources(sources, target);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<DiscoveredDevice?> _promptForAddress() async {
    _manualAddressController.clear();
    return showDialog<DiscoveredDevice>(
      context: context,
      builder: (dialogContext) {
        String? validationMessage;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submitAddress() {
              final input = _manualAddressController.text.trim();
              final address = InternetAddress.tryParse(input);
              if (address == null) {
                setDialogState(() {
                  validationMessage = 'أدخل عنوان IPv4 أو IPv6 صالحًا.';
                });
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
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'أدخل عنوان IP للجهاز المستلم على الشبكة المحلية.',
                  ),
                  const SizedBox(height: 14),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _manualAddressController,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: 'مثال: 192.168.1.25',
                        errorText: validationMessage,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => submitAddress(),
                    ),
                  ),
                ],
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
  }

  Future<void> _sendToManualAddress() async {
    final device = await _promptForAddress();
    if (device != null && mounted) {
      await _pickFilesAndSend(device: device);
    }
  }

  Future<void> _sendToDevice(DiscoveredDevice device) async {
    if (!device.canConnect) {
      final manualDevice = await _promptForAddress();
      if (manualDevice == null || !mounted) return;
      await _pickFilesAndSend(device: manualDevice);
      return;
    }
    await _pickFilesAndSend(device: device);
  }

  Future<DiscoveredDevice?> _chooseDevice() {
    final availableDevices = _discovery.devices
        .where((device) => device.canConnect)
        .toList();
    if (availableDevices.isEmpty) {
      return _promptForAddress();
    }
    if (availableDevices.length == 1) {
      return Future.value(availableDevices.single);
    }

    return showModalBottomSheet<DiscoveredDevice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'اختر الجهاز المستلم',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final device in availableDevices)
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: Text(
                  device.name.isEmpty
                      ? _platformLabel(device.platform)
                      : device.name,
                ),
                subtitle: Text(_platformLabel(device.platform)),
                onTap: () => Navigator.pop(context, device),
              ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.snackbar,
        ),
      );
  }

  Future<void> _toggleTheme() async {
    try {
      await widget.onToggleTheme();
    } catch (error) {
      if (mounted) {
        _showMessage('تعذّر حفظ إعداد المظهر: $error');
      }
    }
  }

  Future<void> _cancelTransfer(String transferId) async {
    try {
      await _transfers.cancelTransfer(transferId);
      if (mounted) _showMessage('تم إلغاء عملية النقل.');
    } on StateError catch (error) {
      if (mounted) _showMessage(error.message);
    } on SocketException catch (error) {
      if (mounted) _showMessage('تعذّر إكمال الإلغاء: ${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AnimatedBuilder(
        animation: _discovery,
        builder: (context, _) => Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 940;
                final horizontalPadding = constraints.maxWidth >= 700
                    ? 36.0
                    : 16.0;

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1240),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      builder: (context, progress, child) => Opacity(
                        opacity: progress,
                        child: Transform.translate(
                          offset: Offset(0, 12 * (1 - progress)),
                          child: child,
                        ),
                      ),
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          16,
                          horizontalPadding,
                          36,
                        ),
                        children: [
                          _TopBar(
                            isDarkMode: widget.isDarkMode,
                            onToggleTheme: () => unawaited(_toggleTheme()),
                          ),
                          const SizedBox(height: 34),
                          _PageHeading(
                            isSearching: _discovery.isSearching,
                            onSearch: () {
                              if (_transfers.isRunning) {
                                unawaited(_discovery.restart());
                              } else {
                                _showMessage(
                                  _transfers.serverError ??
                                      'خادم الاستقبال المحلي غير جاهز.',
                                );
                              }
                            },
                          ),
                          const SizedBox(height: 20),
                          AnimatedBuilder(
                            animation: _transfers,
                            builder: (context, _) => _LocalAddressPanel(
                              addresses: _transfers.localAddresses,
                              port: _transfers.listeningPort,
                              onRefresh: () =>
                                  unawaited(_transfers.refreshLocalAddresses()),
                              onCopy: (address) =>
                                  unawaited(_copyLocalAddress(address)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          AnimatedBuilder(
                            animation: _hotspot,
                            builder: (context, _) => _LocalHotspotPanel(
                              isAndroid: Platform.isAndroid,
                              isWindows: Platform.isWindows,
                              isActive: _hotspot.isActive,
                              isBusy: _hotspot.isBusy,
                              ssid: _hotspot.ssid,
                              passphrase: _hotspot.passphrase,
                              onToggle: () => unawaited(_toggleHotspot()),
                              onCopy: () =>
                                  unawaited(_copyHotspotCredentials()),
                            ),
                          ),
                          const SizedBox(height: 24),
                          AnimatedBuilder(
                            animation: _transfers,
                            builder: (context, _) => _TransferModeSelector(
                              mode: _mode,
                              pendingIncomingCount: _transfers.transfers
                                  .where((transfer) => transfer.needsApproval)
                                  .length,
                              onChanged: (mode) => setState(() => _mode = mode),
                            ),
                          ),
                          const SizedBox(height: 16),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 260),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 0.025),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: _mode == _HomeMode.send
                                ? Column(
                                    key: const ValueKey<_HomeMode>(
                                      _HomeMode.send,
                                    ),
                                    children: [
                                      if (isWide)
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              flex: 11,
                                              child: _DevicesPanel(
                                                devices: _discovery.devices,
                                                status: _discovery.status,
                                                errorMessage:
                                                    _discovery.errorMessage,
                                                onRetry: () => unawaited(
                                                  _discovery.restart(),
                                                ),
                                                onManualConnect: () =>
                                                    unawaited(
                                                      _sendToManualAddress(),
                                                    ),
                                                onDeviceSelected: (device) =>
                                                    unawaited(
                                                      _sendToDevice(device),
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 20),
                                            Expanded(
                                              flex: 9,
                                              child: _SendPanel(
                                                onChooseFiles: () => unawaited(
                                                  _pickFilesAndSend(),
                                                ),
                                                onFilesDropped:
                                                    _sendDroppedItems,
                                              ),
                                            ),
                                          ],
                                        )
                                      else ...[
                                        _DevicesPanel(
                                          devices: _discovery.devices,
                                          status: _discovery.status,
                                          errorMessage: _discovery.errorMessage,
                                          onRetry: () =>
                                              unawaited(_discovery.restart()),
                                          onManualConnect: () =>
                                              unawaited(_sendToManualAddress()),
                                          onDeviceSelected: (device) =>
                                              unawaited(_sendToDevice(device)),
                                        ),
                                        const SizedBox(height: 16),
                                        _SendPanel(
                                          onChooseFiles: () =>
                                              unawaited(_pickFilesAndSend()),
                                          onFilesDropped: _sendDroppedItems,
                                        ),
                                      ],
                                    ],
                                  )
                                : Column(
                                    key: const ValueKey<_HomeMode>(
                                      _HomeMode.receive,
                                    ),
                                    children: [
                                      AnimatedBuilder(
                                        animation: _transfers,
                                        builder: (context, _) =>
                                            _ReceiveReadyPanel(
                                              isRunning: _transfers.isRunning,
                                              saveDirectory:
                                                  _transfers.saveDirectory,
                                              serverError:
                                                  _transfers.serverError,
                                              onRetry: () => unawaited(
                                                _retryLocalServices(),
                                              ),
                                            ),
                                      ),
                                    ],
                                  ),
                          ),
                          const SizedBox(height: 20),
                          AnimatedBuilder(
                            animation: _transfers,
                            builder: (context, _) => _TransfersPanel(
                              transfers: _transfers.transfers
                                  .where(
                                    (transfer) =>
                                        transfer.direction ==
                                        (_mode == _HomeMode.send
                                            ? TransferDirection.outgoing
                                            : TransferDirection.incoming),
                                  )
                                  .toList(),
                              title: _mode == _HomeMode.send
                                  ? 'الملفات المرسلة'
                                  : 'الملفات المستلمة',
                              serverError: null,
                              saveDirectory: null,
                              onAccept: _transfers.accept,
                              onReject: _transfers.reject,
                              onRetryServer: () =>
                                  unawaited(_retryLocalServices()),
                              onCancel: (id) => unawaited(_cancelTransfer(id)),
                              onRemove: _transfers.removeTransfer,
                            ),
                          ),
                          const SizedBox(height: 18),
                          const _PrivacyNote(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.isDarkMode, required this.onToggleTheme});

  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.brand,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            Icons.swap_horiz_rounded,
            color: AppColors.onBrand,
            size: 27,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'وصلة',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.brandTint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'نقل محلي',
            style: TextStyle(
              color: AppColors.brandDark,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          onPressed: onToggleTheme,
          tooltip: isDarkMode ? 'تفعيل الوضع الفاتح' : 'تفعيل الوضع الداكن',
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surface,
            side: BorderSide(color: AppColors.line),
            fixedSize: const Size(44, 44),
          ),
          icon: Icon(
            isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            size: 20,
          ),
        ),
      ],
    );
  }
}

class _LocalAddressPanel extends StatelessWidget {
  const _LocalAddressPanel({
    required this.addresses,
    required this.port,
    required this.onRefresh,
    required this.onCopy,
  });

  final List<String> addresses;
  final int port;
  final VoidCallback onRefresh;
  final ValueChanged<String> onCopy;

  String _formatAddress(String address) =>
      address.contains(':') ? '[$address]:$port' : '$address:$port';

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          _SectionIcon(
            icon: Icons.lan_rounded,
            background: AppColors.blueTint,
            foreground: AppColors.blue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'عنوان هذا الجهاز',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                if (addresses.isEmpty)
                  Text(
                    'لم يظهر عنوان شبكة بعد. اتصل بالـ Wi-Fi ثم حدّث.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else ...[
                  Text(
                    'أدخله في الجهاز الآخر · المنفذ $port',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final address in addresses)
                        ActionChip(
                          avatar: const Icon(Icons.copy_rounded, size: 15),
                          label: Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(_formatAddress(address)),
                          ),
                          onPressed: () => onCopy(address),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            tooltip: 'تحديث عناوين الشبكة',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.onSearch, required this.isSearching});

  final VoidCallback onSearch;
  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final titleAndSubtitle = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'أرسل واستقبل بسهولة',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 5),
            Text(
              'انقل ملفاتك مباشرةً إلى الأجهزة القريبة على شبكتك.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        );

        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleAndSubtitle,
              const SizedBox(height: 16),
              _SearchButton(
                onPressed: onSearch,
                isSearching: isSearching,
                expanded: true,
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: titleAndSubtitle),
            const SizedBox(width: 16),
            _SearchButton(onPressed: onSearch, isSearching: isSearching),
          ],
        );
      },
    );
  }
}

class _LocalHotspotPanel extends StatelessWidget {
  const _LocalHotspotPanel({
    required this.isAndroid,
    required this.isWindows,
    required this.isActive,
    required this.isBusy,
    required this.ssid,
    required this.passphrase,
    required this.onToggle,
    required this.onCopy,
  });

  final bool isAndroid;
  final bool isWindows;
  final bool isActive;
  final bool isBusy;
  final String? ssid;
  final String? passphrase;
  final VoidCallback onToggle;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(
                icon: Icons.wifi_tethering_rounded,
                background: AppColors.blueTint,
                foreground: AppColors.brandDark,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'اتصال مباشر بدون راوتر',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'انقل الملفات عبر شبكة محلية مباشرة، بدون إنترنت.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isAndroid) ...[
            if (isActive) ...[
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HotspotCredential(label: 'اسم الشبكة', value: ssid ?? ''),
                    if (passphrase != null)
                      _HotspotCredential(
                        label: 'كلمة المرور',
                        value: passphrase!,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('نسخ بيانات الاتصال'),
                  ),
                  OutlinedButton.icon(
                    onPressed: isBusy ? null : onToggle,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('إيقاف نقطة الاتصال'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'من الجهاز الآخر، اتصل بهذه الشبكة من إعدادات Wi-Fi ثم اترك وصلة مفتوحًا على الجهازين.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ] else ...[
              Text(
                'أنشئ نقطة اتصال محلية مؤقتة من هاتف Android، ثم صِل الكمبيوتر أو الهاتف الآخر بها. لا تستهلك بيانات الإنترنت.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: isBusy ? null : onToggle,
                icon: isBusy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.onBrand,
                        ),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 19),
                label: Text(
                  isBusy ? 'جارٍ إنشاء نقطة الاتصال...' : 'إنشاء نقطة اتصال',
                ),
              ),
            ],
          ] else if (isWindows) ...[
            Text(
              'للاتصال المباشر بهاتف Android، افتح إعدادات Windows ثم '
              'Network & Internet > Mobile hotspot وفعّل نقطة الاتصال إذا '
              'كان محول Wi-Fi يدعم ذلك. بعد ذلك، صِل الهاتف بشبكة Windows '
              'مع إبقاء التطبيق مفتوحًا على الجهازين.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ] else ...[
            Text(
              'ابدأ نقطة الاتصال من هاتف Android، ثم صِل هذا الجهاز بها من إعدادات Wi-Fi.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

class _HotspotCredential extends StatelessWidget {
  const _HotspotCredential({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text('$label: ', style: Theme.of(context).textTheme.bodyMedium),
          Flexible(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({
    required this.onPressed,
    required this.isSearching,
    this.expanded = false,
  });

  final VoidCallback onPressed;
  final bool isSearching;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expanded ? double.infinity : null,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: isSearching
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.onBrand,
                ),
              )
            : const Icon(Icons.radar_rounded, size: 19),
        label: Text(isSearching ? 'تحديث البحث' : 'ابحث عن أجهزة'),
      ),
    );
  }
}

class _TransferModeSelector extends StatelessWidget {
  const _TransferModeSelector({
    required this.mode,
    required this.pendingIncomingCount,
    required this.onChanged,
  });

  final _HomeMode mode;
  final int pendingIncomingCount;
  final ValueChanged<_HomeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          _ModeButton(
            label: 'إرسال',
            icon: Icons.upload_rounded,
            selected: mode == _HomeMode.send,
            badgeCount: 0,
            onTap: () => onChanged(_HomeMode.send),
          ),
          const SizedBox(width: 6),
          _ModeButton(
            label: 'استقبال',
            icon: Icons.download_rounded,
            selected: mode == _HomeMode.receive,
            badgeCount: pendingIncomingCount,
            onTap: () => onChanged(_HomeMode.receive),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.badgeCount,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? AppColors.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 19,
                    color: selected ? AppColors.onBrand : AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? AppColors.onBrand : AppColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (badgeCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.brand : AppColors.onBrand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _arabicDigits(badgeCount),
                        style: TextStyle(
                          color: selected ? AppColors.brand : AppColors.onBrand,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReceiveReadyPanel extends StatelessWidget {
  const _ReceiveReadyPanel({
    required this.isRunning,
    required this.saveDirectory,
    required this.serverError,
    required this.onRetry,
  });

  final bool isRunning;
  final String? saveDirectory;
  final String? serverError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(
                icon: Icons.download_rounded,
                background: AppColors.brandTint,
                foreground: AppColors.brand,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRunning ? 'الاستقبال جاهز' : 'الاستقبال غير متاح',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isRunning
                          ? 'اتصل بنفس شبكة Wi-Fi ووافق على طلب الإرسال عند ظهوره.'
                          : 'تعذّر بدء خادم الاستقبال المحلي.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Icon(
                isRunning ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                color: isRunning ? AppColors.brand : AppColors.danger,
              ),
            ],
          ),
          if (saveDirectory != null) ...[
            const SizedBox(height: 16),
            _TransferNotice(
              icon: Icons.folder_open_outlined,
              color: AppColors.muted,
              text: 'مكان حفظ الملفات: $saveDirectory',
            ),
          ],
          if (!isRunning && serverError != null) ...[
            const SizedBox(height: 12),
            _TransferNotice(
              icon: Icons.error_outline_rounded,
              color: AppColors.danger,
              text: serverError!,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('إعادة المحاولة'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DevicesPanel extends StatelessWidget {
  const _DevicesPanel({
    required this.devices,
    required this.status,
    required this.errorMessage,
    required this.onRetry,
    required this.onManualConnect,
    required this.onDeviceSelected,
  });

  final List<DiscoveredDevice> devices;
  final DeviceDiscoveryStatus status;
  final String? errorMessage;
  final VoidCallback onRetry;
  final VoidCallback onManualConnect;
  final ValueChanged<DiscoveredDevice> onDeviceSelected;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(
                icon: Icons.devices_rounded,
                background: AppColors.blueTint,
                foreground: AppColors.blue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '١ · اختر الجهاز المستلم',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'اختر جهازًا قريبًا أو أدخل عنوان IP يدويًا',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_arabicDigits(devices.length)} أجهزة',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: devices.isEmpty ? 230 : 100),
            padding: EdgeInsets.all(devices.isEmpty ? 22 : 10),
            decoration: BoxDecoration(
              color: AppColors.tile,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.line),
            ),
            child: devices.isEmpty
                ? _EmptyDevicesState(
                    status: status,
                    errorMessage: errorMessage,
                    onRetry: onRetry,
                  )
                : Column(
                    children: [
                      for (var index = 0; index < devices.length; index++) ...[
                        _DeviceTile(
                          device: devices[index],
                          onTap: () => onDeviceSelected(devices[index]),
                        ),
                        if (index != devices.length - 1)
                          Divider(height: 1, color: AppColors.line),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: onManualConnect,
              icon: const Icon(Icons.pin_drop_outlined, size: 18),
              label: const Text('إدخال عنوان IP يدويًا'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDevicesState extends StatelessWidget {
  const _EmptyDevicesState({
    required this.status,
    required this.errorMessage,
    required this.onRetry,
  });

  final DeviceDiscoveryStatus status;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isStarting = status == DeviceDiscoveryStatus.starting;
    final hasError = status == DeviceDiscoveryStatus.error;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 76,
          height: 76,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: AppColors.brandTint,
                  shape: BoxShape.circle,
                ),
              ),
              Icon(
                hasError ? Icons.wifi_off_rounded : Icons.devices_other_rounded,
                color: hasError ? AppColors.danger : AppColors.brand,
                size: 34,
              ),
              if (!hasError)
                Positioned(
                  bottom: 1,
                  right: 1,
                  child: SizedBox(
                    width: 23,
                    height: 23,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brand,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 15),
        Text(
          hasError
              ? 'تعذّر بدء اكتشاف الأجهزة'
              : isStarting
              ? 'جارٍ تهيئة اكتشاف الأجهزة...'
              : 'جارٍ البحث عن الأجهزة القريبة...',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 5),
        Text(
          hasError
              ? (errorMessage ?? 'تحقق من إعدادات الشبكة وحاول مرة أخرى.')
              : 'تأكد من اتصال الأجهزة بشبكة Wi-Fi نفسها.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasError) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('إعادة المحاولة'),
          ),
        ],
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap});

  final DiscoveredDevice device;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (device.platform) {
      'android' => ('أندرويد', Icons.phone_android_rounded),
      'ios' => ('آيفون أو آيباد', Icons.phone_iphone_rounded),
      'windows' => ('Windows', Icons.desktop_windows_rounded),
      'macos' => ('Mac', Icons.laptop_mac_rounded),
      'linux' => ('Linux', Icons.computer_rounded),
      _ => ('جهاز قريب', Icons.devices_rounded),
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.brandTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppColors.brand, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name.isNotEmpty
                          ? device.name
                          : '$label · ${device.id.substring(0, device.id.length < 4 ? device.id.length : 4).toUpperCase()}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.canConnect
                          ? 'متاح للإرسال · ${_platformLabel(device.platform)}'
                          : device.resolutionFailed
                          ? 'تعذّر تحديد العنوان؛ أدخل IP يدويًا أو حاول لاحقًا'
                          : 'جارٍ تحديد عنوان الجهاز...',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Icon(
                device.canConnect
                    ? Icons.arrow_back_rounded
                    : Icons.edit_location_alt_outlined,
                size: 19,
                color: device.canConnect ? AppColors.brand : AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _arabicDigits(int value) {
  const digits = '٠١٢٣٤٥٦٧٨٩';
  return value.toString().split('').map((character) {
    final digit = int.tryParse(character);
    return digit == null ? character : digits[digit];
  }).join();
}

String _platformLabel(String platform) => switch (platform) {
  'android' => 'هاتف أندرويد',
  'ios' => 'آيفون أو آيباد',
  'windows' => 'جهاز Windows',
  'macos' => 'جهاز Mac',
  'linux' => 'جهاز Linux',
  _ => 'جهاز قريب',
};

class _SendPanel extends StatefulWidget {
  const _SendPanel({required this.onChooseFiles, required this.onFilesDropped});

  final VoidCallback onChooseFiles;
  final Future<void> Function(List<DropItem>) onFilesDropped;

  @override
  State<_SendPanel> createState() => _SendPanelState();
}

class _SendPanelState extends State<_SendPanel> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final supportsDesktopDrop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(
                icon: Icons.upload_file_rounded,
                background: AppColors.brandTint,
                foreground: AppColors.brand,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '٢ · اختر الملفات',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'بعد اختيار المستلم، حدد ما تريد إرساله',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          DropTarget(
            onDragDone: (details) {
              setState(() => _isDragging = false);
              unawaited(widget.onFilesDropped(details.files));
            },
            onDragEntered: (_) => setState(() => _isDragging = true),
            onDragExited: (_) => setState(() => _isDragging = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: double.infinity,
              constraints: BoxConstraints(
                minHeight: supportsDesktopDrop ? 200 : 176,
              ),
              padding: EdgeInsets.all(supportsDesktopDrop ? 22 : 16),
              decoration: BoxDecoration(
                color: _isDragging
                    ? AppColors.brandTint
                    : AppColors.dropSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _isDragging ? AppColors.brand : AppColors.dropBorder,
                  width: _isDragging ? 2 : 1.3,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: AppColors.brandTint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.cloud_upload_outlined,
                      color: AppColors.brand,
                      size: 29,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    supportsDesktopDrop
                        ? 'أفلت ملفاتك هنا'
                        : 'اختر ملفات للإرسال',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'أو اختر ملفات من جهازك للإرسال',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: widget.onChooseFiles,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('اختر الجهاز والملفات'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.wifi_rounded, size: 16, color: AppColors.brand),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  'نقل مباشر بين أجهزتك عبر الشبكة المحلية',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransfersPanel extends StatelessWidget {
  const _TransfersPanel({
    required this.transfers,
    required this.title,
    required this.serverError,
    required this.saveDirectory,
    required this.onAccept,
    required this.onReject,
    required this.onRetryServer,
    required this.onCancel,
    required this.onRemove,
  });

  final List<TransferSnapshot> transfers;
  final String title;
  final String? serverError;
  final String? saveDirectory;
  final ValueChanged<String> onAccept;
  final ValueChanged<String> onReject;
  final VoidCallback onRetryServer;
  final ValueChanged<String> onCancel;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(
                icon: Icons.swap_vert_rounded,
                background: AppColors.orangeTint,
                foreground: AppColors.orange,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      transfers.isEmpty
                          ? 'ستظهر هنا حالة الملفات وسرعة النقل.'
                          : '${_arabicDigits(transfers.length)} عمليات نقل',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (serverError != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _TransferNotice(
                    icon: Icons.error_outline_rounded,
                    color: AppColors.danger,
                    text:
                        'تعذّر تشغيل خادم الاستقبال على المنفذ 53317: $serverError',
                  ),
                ),
                TextButton.icon(
                  onPressed: onRetryServer,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ],
          if (saveDirectory != null) ...[
            const SizedBox(height: 12),
            _TransferNotice(
              icon: Icons.folder_open_outlined,
              color: AppColors.muted,
              text: 'مجلد الحفظ: $saveDirectory',
            ),
          ],
          if (transfers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: AppColors.line),
            for (var index = 0; index < transfers.length; index++) ...[
              _TransferRow(
                transfer: transfers[index],
                onAccept: () => onAccept(transfers[index].id),
                onReject: () => onReject(transfers[index].id),
                onCancel: () => onCancel(transfers[index].id),
                onRemove: () => onRemove(transfers[index].id),
              ),
              if (index != transfers.length - 1)
                Divider(height: 1, color: AppColors.line),
            ],
          ],
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.transfer,
    required this.onAccept,
    required this.onReject,
    required this.onCancel,
    required this.onRemove,
  });

  final TransferSnapshot transfer;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final incoming = transfer.direction == TransferDirection.incoming;
    final status = transfer.isCancelling
        ? 'جارٍ إلغاء النقل...'
        : switch (transfer.status) {
            TransferStatus.requesting => 'جارٍ طلب الموافقة من المستلم...',
            TransferStatus.awaitingApproval =>
              'يريد ${_platformLabel(transfer.peerName)} إرسال ملف إليك',
            TransferStatus.waitingForUpload =>
              'تمت الموافقة؛ جارٍ انتظار الملف...',
            TransferStatus.transferring =>
              '${_formatBytes(transfer.transferredBytes)} / ${_formatBytes(transfer.totalBytes)} · '
                  '${(transfer.progress * 100).toStringAsFixed(1)}٪ · '
                  '${_formatSpeed(transfer.bytesPerSecond)}',
            TransferStatus.completed =>
              incoming ? 'اكتمل الاستقبال' : 'اكتمل الإرسال',
            TransferStatus.rejected => 'تم رفض الاستقبال',
            TransferStatus.failed => transfer.errorMessage ?? 'فشل نقل الملف',
            TransferStatus.cancelled =>
              transfer.errorMessage ?? 'تم إلغاء عملية النقل',
          };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                incoming ? Icons.download_rounded : Icons.upload_rounded,
                color: AppColors.brand,
                size: 19,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  transfer.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatBytes(transfer.totalBytes),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (transfer.isActive && !transfer.needsApproval)
                IconButton(
                  onPressed: transfer.canCancel ? onCancel : null,
                  tooltip: transfer.isCancelling
                      ? 'جارٍ إلغاء النقل'
                      : 'إلغاء النقل',
                  visualDensity: VisualDensity.compact,
                  icon: transfer.canCancel
                      ? const Icon(Icons.cancel_outlined)
                      : const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                  color: AppColors.danger,
                )
              else if (!transfer.isActive)
                IconButton(
                  onPressed: transfer.canRemove ? onRemove : null,
                  tooltip: 'إزالة من السجل',
                  visualDensity: VisualDensity.compact,
                  icon: transfer.canRemove
                      ? const Icon(Icons.delete_outline_rounded)
                      : const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(status, style: Theme.of(context).textTheme.bodyMedium),
          if (transfer.pairingCode != null &&
              (transfer.status == TransferStatus.requesting ||
                  transfer.status == TransferStatus.awaitingApproval)) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.blueTint,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'رمز التحقق: ${transfer.pairingCode}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    incoming
                        ? 'قارن الرمز مع المرسل عبر وسيلة موثوقة. ارفض النقل إذا اختلف.'
                        : 'تأكد أن الرمز مطابق لما يظهر على جهاز الاستقبال.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
          if (transfer.status == TransferStatus.transferring ||
              transfer.status == TransferStatus.completed) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: transfer.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(8),
              backgroundColor: AppColors.line,
              color: AppColors.brand,
            ),
          ],
          if (transfer.needsApproval) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 9,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('تحقق من الرمز ثم قبول'),
                ),
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('رفض'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TransferNotice extends StatelessWidget {
  const _TransferNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 11, height: 1.5),
          ),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

String _formatSpeed(double bytesPerSecond) =>
    '${_formatBytes(bytesPerSecond.round())}/ث';

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.info_outline_rounded, size: 15, color: AppColors.muted),
        SizedBox(width: 7),
        Flexible(
          child: Text(
            'النقل مشفّر أثناء الإرسال؛ طابق رمز التحقق قبل القبول. الملفات المحفوظة غير مشفّرة.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(22)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.line),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 22,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, color: foreground, size: 21),
    );
  }
}
