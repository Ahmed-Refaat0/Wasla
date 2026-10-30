import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum LocalHotspotStatus { idle, starting, active, stopping, error }

class LocalHotspotController extends ChangeNotifier {
  LocalHotspotController({
    this.channel = _defaultChannel,
    bool Function()? isAndroid,
  }) : _isAndroid = isAndroid ?? (() => Platform.isAndroid) {
    channel.setMethodCallHandler(_handleNativeCall);
  }

  static const _defaultChannel = MethodChannel('wasla/local_hotspot');

  final MethodChannel channel;
  final bool Function() _isAndroid;
  LocalHotspotStatus _status = LocalHotspotStatus.idle;
  String? _ssid;
  String? _passphrase;
  String? _errorMessage;
  bool _disposed = false;

  LocalHotspotStatus get status => _status;
  String? get ssid => _ssid;
  String? get passphrase => _passphrase;
  String? get errorMessage => _errorMessage;
  bool get isActive => _status == LocalHotspotStatus.active;
  bool get isBusy =>
      _status == LocalHotspotStatus.starting ||
      _status == LocalHotspotStatus.stopping;

  Future<void> start() async {
    if (!_isAndroid()) {
      throw UnsupportedError(
        'إنشاء نقطة اتصال من داخل التطبيق متاح على Android فقط.',
      );
    }
    if (isBusy || isActive) return;

    _status = LocalHotspotStatus.starting;
    _errorMessage = null;
    _notifyListeners();

    try {
      final result = await channel.invokeMapMethod<String, Object?>('start');
      final ssid = result?['ssid'];
      final passphrase = result?['passphrase'];
      if (ssid is! String || ssid.isEmpty) {
        throw const FormatException('لم يُرجع Android اسم نقطة الاتصال.');
      }

      _ssid = ssid;
      _passphrase = passphrase is String ? passphrase : null;
      _status = LocalHotspotStatus.active;
      _notifyListeners();
    } catch (error) {
      _status = LocalHotspotStatus.error;
      _errorMessage = error.toString();
      _notifyListeners();
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_isAndroid()) {
      throw UnsupportedError(
        'إيقاف نقطة الاتصال من داخل التطبيق متاح على Android فقط.',
      );
    }
    if (!isActive) return;

    _status = LocalHotspotStatus.stopping;
    _notifyListeners();
    try {
      await channel.invokeMethod<void>('stop');
      _clearHotspot();
    } catch (error) {
      _status = LocalHotspotStatus.error;
      _errorMessage = error.toString();
      _notifyListeners();
      rethrow;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'stopped') {
      throw MissingPluginException(
        'Unknown local-hotspot callback: ${call.method}',
      );
    }
    _clearHotspot();
    return null;
  }

  void _clearHotspot() {
    _status = LocalHotspotStatus.idle;
    _ssid = null;
    _passphrase = null;
    _errorMessage = null;
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
