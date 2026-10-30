import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../domain/discovered_device.dart';

enum DeviceDiscoveryStatus { idle, starting, searching, error }

class DeviceDiscoveryController extends ChangeNotifier {
  DeviceDiscoveryController();

  static const serviceType = '_wasla._tcp';

  static const advertisedPort = 53317;

  final String _deviceId = _createDeviceId();
  final Map<String, DiscoveredDevice> _devices = {};

  BonsoirDiscovery? _discovery;
  BonsoirBroadcast? _broadcast;
  StreamSubscription<BonsoirEvent>? _eventSubscription;
  DeviceDiscoveryStatus _status = DeviceDiscoveryStatus.idle;
  String? _errorMessage;
  bool _disposed = false;

  DeviceDiscoveryStatus get status => _status;
  String? get errorMessage => _errorMessage;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices.values);
  bool get isSearching =>
      _status == DeviceDiscoveryStatus.starting ||
      _status == DeviceDiscoveryStatus.searching;

  Future<void> start() async {
    if (_disposed || isSearching) return;

    _status = DeviceDiscoveryStatus.starting;
    _errorMessage = null;
    _devices.clear();
    _notifyListeners();

    try {
      final discovery = BonsoirDiscovery(type: serviceType);
      _discovery = discovery;
      await discovery.initialize();
      if (_disposed) return;

      final eventStream = discovery.eventStream;
      if (eventStream == null) {
        throw StateError('Bonsoir discovery did not expose its event stream.');
      }

      _eventSubscription = eventStream.listen(
        _handleDiscoveryEvent,
        onError: (Object error, StackTrace stackTrace) {
          _setError(error, stackTrace, 'Discovery event stream failed.');
        },
      );

      final service = BonsoirService(
        name: 'Wasla-${Platform.operatingSystem}-$_deviceId',
        type: serviceType,
        port: advertisedPort,
        attributes: {
          'deviceid': _deviceId,
          'platform': Platform.operatingSystem,
          'protocolversion': '1',
        },
      );
      final broadcast = BonsoirBroadcast(service: service);
      _broadcast = broadcast;
      await broadcast.initialize();
      if (_disposed) return;
      await broadcast.start();
      if (_disposed) return;
      await discovery.start();

      if (_disposed) return;
      _status = DeviceDiscoveryStatus.searching;
      _notifyListeners();
    } catch (error, stackTrace) {
      await _stopActions();
      _setError(error, stackTrace, 'Could not start local network discovery.');
    }
  }

  Future<void> restart() async {
    if (_disposed || _status == DeviceDiscoveryStatus.starting) return;
    await _stopActions();
    if (_disposed) return;
    _status = DeviceDiscoveryStatus.idle;
    _notifyListeners();
    await start();
  }

  void _handleDiscoveryEvent(BonsoirEvent event) {
    try {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          final service = event.service;
          if (_isOwnService(service)) return;
          _upsertDevice(service, isResolved: false);
          service.resolve(_discovery!.serviceResolver);
          break;
        case BonsoirDiscoveryServiceResolvedEvent():
          final service = event.service;
          if (_isOwnService(service)) return;
          _upsertDevice(service, isResolved: true);
          break;
        case BonsoirDiscoveryServiceUpdatedEvent():
          final service = event.service;
          if (_isOwnService(service)) return;
          _upsertDevice(
            service,
            isResolved: service.hostAddresses.isNotEmpty,
          );
          break;
        case BonsoirDiscoveryServiceLostEvent():
          final service = event.service;
          _devices.remove(_deviceKey(service));
          _notifyListeners();
          break;
        default:
          break;
      }
    } catch (error, stackTrace) {
      _setError(error, stackTrace, 'Could not process a discovery event.');
    }
  }

  bool _isOwnService(BonsoirService service) =>
      service.attributes['deviceid'] == _deviceId;

  void _upsertDevice(BonsoirService service, {required bool isResolved}) {
    final key = _deviceKey(service);
    _devices[key] = DiscoveredDevice(
      id: service.attributes['deviceid'] ?? key,
      platform: service.attributes['platform'] ?? 'unknown',
      addresses: List.unmodifiable(service.hostAddresses),
      port: service.port,
      isResolved: isResolved,
    );
    _notifyListeners();
  }

  String _deviceKey(BonsoirService service) =>
      service.attributes['deviceid'] ?? service.name;

  Future<void> _stopActions() async {
    final subscription = _eventSubscription;
    _eventSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        _reportError(error, stackTrace, 'Could not stop the discovery listener.');
      }
    }

    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      try {
        await discovery.stop();
      } catch (error, stackTrace) {
        _reportError(error, stackTrace, 'Could not stop mDNS discovery.');
      }
    }

    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null) {
      try {
        await broadcast.stop();
      } catch (error, stackTrace) {
        _reportError(error, stackTrace, 'Could not stop the mDNS broadcast.');
      }
    }
  }

  void _setError(Object error, StackTrace stackTrace, String context) {
    _errorMessage = error.toString();
    _status = DeviceDiscoveryStatus.error;
    _reportError(error, stackTrace, context);
    _notifyListeners();
  }

  void _reportError(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Wasla device discovery',
        context: ErrorDescription(context),
      ),
    );
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  static String _createDeviceId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopActions());
    super.dispose();
  }
}
