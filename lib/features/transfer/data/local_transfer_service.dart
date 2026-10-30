import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../devices/domain/discovered_device.dart';
import 'android_download_publisher.dart';
import '../domain/transfer_file_source.dart';
import '../domain/transfer_snapshot.dart';

class LocalTransferService extends ChangeNotifier {
  static const int port = 53317;
  static const int maxFileSizeBytes = 50 * 1024 * 1024 * 1024;
  static const int _maxOfferBodyBytes = 16 * 1024;
  static const int _maxPendingOffers = 4;
  static const Duration _offerTimeout = Duration(minutes: 2);

  LocalTransferService({
    int? serverPort,
    Future<Directory?> Function()? downloadsDirectoryProvider,
    Future<Directory> Function()? documentsDirectoryProvider,
    AndroidDownloadPublisher? androidDownloadPublisher,
    bool Function()? isAndroid,
  }) : _serverPort = serverPort ?? port,
       _downloadsDirectoryProvider =
           downloadsDirectoryProvider ?? getDownloadsDirectory,
       _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _androidDownloadPublisher =
           androidDownloadPublisher ?? AndroidDownloadPublisher(),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final int _serverPort;
  final Future<Directory?> Function() _downloadsDirectoryProvider;
  final Future<Directory> Function() _documentsDirectoryProvider;
  final AndroidDownloadPublisher _androidDownloadPublisher;
  final bool Function() _isAndroid;
  final Map<String, _TransferRecord> _records = {};
  final Set<String> _reservedDestinations = {};
  HttpServer? _server;
  HttpClient? _httpClient;
  bool _disposed = false;
  String? _serverError;
  String? _saveDirectory;

  bool get isRunning => _server != null;
  int get listeningPort => _server?.port ?? _serverPort;
  String? get serverError => _serverError;
  String? get saveDirectory => _saveDirectory;

  List<TransferSnapshot> get transfers {
    final snapshots = _records.values.map((record) => record.snapshot).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(snapshots);
  }

  Future<void> start() async {
    if (_disposed || _server != null) return;
    _serverError = null;

    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _serverPort,
        shared: false,
      );
      if (_disposed) {
        await server.close(force: true);
        return;
      }

      _server = server;
      _httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 30);
      server.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error, StackTrace stackTrace) {
          _reportError(error, stackTrace, 'Local HTTP server failed.');
        },
      );
      _notifyListeners();
    } catch (error, stackTrace) {
      _serverError = error.toString();
      _reportError(error, stackTrace, 'Could not start the file receiver.');
      _notifyListeners();
    }
  }

  Future<void> sendFiles(List<File> files, DiscoveredDevice device) async {
    final sources = await Future.wait(
      files.map(
        (file) async => TransferFileSource(
          name: file.uri.pathSegments.isEmpty
              ? 'file'
              : file.uri.pathSegments.last,
          size: await file.length(),
          openRead: file.openRead,
        ),
      ),
    );
    await sendSources(sources, device);
  }

  Future<void> sendSources(
    List<TransferFileSource> sources,
    DiscoveredDevice device,
  ) async {
    if (!isRunning) {
      throw StateError('The local file receiver is not running.');
    }
    if (!device.canConnect) {
      throw StateError('The selected device has no resolved network address.');
    }

    final address = _selectAddress(device);
    for (final source in sources) {
      await _sendFile(source, device, address);
    }
  }

  Future<void> _sendFile(
    TransferFileSource source,
    DiscoveredDevice device,
    String address,
  ) async {
    final record = _TransferRecord(
      id: _randomHex(16),
      fileName: _safeFileName(source.name),
      direction: TransferDirection.outgoing,
      status: TransferStatus.requesting,
      totalBytes: source.size,
      peerName: device.name.isEmpty ? device.platform : device.name,
    );
    if (record.totalBytes > maxFileSizeBytes) {
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'الحد الأقصى لحجم الملف هو ٥٠ جيجابايت.';
      _records[record.id] = record;
      _notifyListeners();
      return;
    }

    _records[record.id] = record;
    _notifyListeners();

    try {
      final client = _httpClient;
      if (client == null) throw StateError('HTTP client is not available.');
      final baseUri = Uri(scheme: 'http', host: address, port: device.port);
      final offerRequest = await client.postUrl(
        baseUri.replace(path: '/v1/offers'),
      );
      offerRequest.headers.contentType = ContentType.json;
      offerRequest.write(
        jsonEncode({
          'id': record.id,
          'name': record.fileName,
          'size': record.totalBytes,
          'sender': Platform.operatingSystem,
        }),
      );
      final offerResponse = await offerRequest.close();
      final offerBody = await _readResponseBody(offerResponse);
      if (offerResponse.statusCode != HttpStatus.ok) {
        final message = _readErrorMessage(offerBody);
        throw HttpException(message, uri: baseUri);
      }

      final offer = jsonDecode(offerBody);
      if (offer is! Map<String, dynamic> || offer['token'] is! String) {
        throw const FormatException(
          'The receiving device returned an invalid offer response.',
        );
      }

      record.status = TransferStatus.transferring;
      _notifyListeners();

      final uploadRequest = await client.putUrl(
        baseUri.replace(path: '/v1/files/${record.id}'),
      );
      uploadRequest.headers.contentType = ContentType.binary;
      uploadRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${offer['token']}',
      );
      uploadRequest.contentLength = record.totalBytes;
      final stopwatch = Stopwatch()..start();
      var lastNotification = Duration.zero;
      await uploadRequest.addStream(
        source.openRead().transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              sink.add(chunk);
              record.transferredBytes += chunk.length;
              record.bytesPerSecond = stopwatch.elapsedMicroseconds == 0
                  ? 0
                  : record.transferredBytes *
                        Duration.microsecondsPerSecond /
                        stopwatch.elapsedMicroseconds;
              if (stopwatch.elapsed - lastNotification >=
                  const Duration(milliseconds: 100)) {
                lastNotification = stopwatch.elapsed;
                _notifyListeners();
              }
            },
          ),
        ),
      );

      final uploadResponse = await uploadRequest.close();
      final responseBody = await _readResponseBody(uploadResponse);
      if (uploadResponse.statusCode != HttpStatus.created) {
        throw HttpException(_readErrorMessage(responseBody), uri: baseUri);
      }

      record
        ..status = TransferStatus.completed
        ..transferredBytes = record.totalBytes;
      _notifyListeners();
      _trimRecords();
    } catch (error, stackTrace) {
      record
        ..status = TransferStatus.failed
        ..errorMessage = error.toString();
      _reportError(error, stackTrace, 'Could not send ${record.fileName}.');
      _notifyListeners();
      _trimRecords();
    }
  }

  void accept(String transferId) {
    final record = _records[transferId];
    if (record == null ||
        record.status != TransferStatus.awaitingApproval ||
        record.decision == null) {
      return;
    }

    record.status = TransferStatus.waitingForUpload;
    record.uploadTimer = Timer(_offerTimeout, () {
      if (record.status != TransferStatus.waitingForUpload) return;
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'انتهت مهلة بدء إرسال الملف.'
        ..token = null
        ..uploadTimer = null;
      _notifyListeners();
      _trimRecords();
    });
    record.decision!.complete(true);
    _notifyListeners();
  }

  void reject(String transferId) {
    final record = _records[transferId];
    if (record == null ||
        record.status != TransferStatus.awaitingApproval ||
        record.decision == null) {
      return;
    }

    record
      ..status = TransferStatus.rejected
      ..token = null
      ..decision!.complete(false);
    _notifyListeners();
    _trimRecords();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, {'status': 'ready'});
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/v1/offers') {
        await _handleOffer(request);
        return;
      }

      if (request.method == 'PUT' &&
          request.uri.pathSegments.length == 3 &&
          request.uri.pathSegments[0] == 'v1' &&
          request.uri.pathSegments[1] == 'files') {
        await _handleUpload(request, request.uri.pathSegments[2]);
        return;
      }

      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'المسار المطلوب غير موجود.',
      });
    } catch (error, stackTrace) {
      _reportError(error, stackTrace, 'Could not handle an HTTP request.');
      try {
        await request.response.close();
      } on HttpException catch (closeError, closeStackTrace) {
        _reportError(
          closeError,
          closeStackTrace,
          'Could not close the failed HTTP response.',
        );
      } on StateError catch (closeError, closeStackTrace) {
        _reportError(
          closeError,
          closeStackTrace,
          'Could not close the failed HTTP response.',
        );
      }
    }
  }

  Future<void> _handleOffer(HttpRequest request) async {
    if (request.contentLength > _maxOfferBodyBytes) {
      request.response.persistentConnection = false;
      await _writeJson(request.response, HttpStatus.requestEntityTooLarge, {
        'error': 'بيانات طلب النقل أكبر من الحد المسموح.',
      });
      return;
    }

    String body;
    try {
      body = await _readSmallBody(request);
    } on FormatException {
      request.response.persistentConnection = false;
      await _writeJson(request.response, HttpStatus.requestEntityTooLarge, {
        'error': 'بيانات طلب النقل أكبر من الحد المسموح.',
      });
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات طلب النقل غير صالحة.',
      });
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات طلب النقل غير صالحة.',
      });
      return;
    }

    final id = decoded['id'];
    final name = decoded['name'];
    final size = decoded['size'];
    final sender = decoded['sender'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        name is! String ||
        size is! int ||
        size < 0 ||
        size > maxFileSizeBytes ||
        sender is! String) {
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات الملف غير مكتملة أو حجم الملف غير مقبول.',
      });
      return;
    }

    if (_records.values.any((record) => record.id == id)) {
      await _writeJson(request.response, HttpStatus.conflict, {
        'error': 'معرّف النقل مستخدم بالفعل.',
      });
      return;
    }

    final pendingCount = _records.values
        .where((record) => record.status == TransferStatus.awaitingApproval)
        .length;
    if (pendingCount >= _maxPendingOffers) {
      await _writeJson(request.response, HttpStatus.tooManyRequests, {
        'error': 'هناك طلبات نقل معلّقة كثيرة؛ حاول لاحقًا.',
      });
      return;
    }

    final record =
        _TransferRecord(
            id: id,
            fileName: _safeFileName(name),
            direction: TransferDirection.incoming,
            status: TransferStatus.awaitingApproval,
            totalBytes: size,
            peerName: sender,
          )
          ..token = _randomHex(32)
          ..decision = Completer<bool>();
    _records[id] = record;
    _notifyListeners();

    final accepted = await record.decision!.future.timeout(
      _offerTimeout,
      onTimeout: () => false,
    );
    if (!accepted) {
      if (record.status == TransferStatus.awaitingApproval) {
        record
          ..status = TransferStatus.failed
          ..errorMessage = 'انتهت مهلة الموافقة على طلب الاستقبال.'
          ..token = null;
        _notifyListeners();
      }
      await _writeJson(
        request.response,
        record.status == TransferStatus.rejected
            ? HttpStatus.forbidden
            : HttpStatus.requestTimeout,
        {'error': 'لم تتم الموافقة على استقبال الملف.'},
      );
      _trimRecords();
      return;
    }

    await _writeJson(request.response, HttpStatus.ok, {'token': record.token});
  }

  Future<void> _handleUpload(HttpRequest request, String id) async {
    final record = _records[id];
    if (record == null ||
        record.direction != TransferDirection.incoming ||
        record.status != TransferStatus.waitingForUpload) {
      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'طلب استقبال الملف غير موجود أو لم تتم الموافقة عليه.',
      });
      return;
    }

    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (authorization != 'Bearer ${record.token}') {
      await _writeJson(request.response, HttpStatus.forbidden, {
        'error': 'رمز استقبال الملف غير صالح.',
      });
      return;
    }

    if (request.contentLength != record.totalBytes) {
      request.response.persistentConnection = false;
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'حجم الملف المرسل لا يطابق الحجم المعلن.',
      });
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'حجم الملف المرسل لا يطابق الحجم المعلن.'
        ..token = null;
      _notifyListeners();
      return;
    }

    record.uploadTimer?.cancel();
    record.uploadTimer = null;
    record.status = TransferStatus.transferring;
    record.token = null;
    _notifyListeners();

    File? partialFile;
    RandomAccessFile? sink;
    try {
      final directory = await _ensureSaveDirectory();
      final destination = await _availableDestination(
        directory,
        record.fileName,
      );
      partialFile = File(destination);
      sink = await partialFile.open(mode: FileMode.writeOnly);
      final stopwatch = Stopwatch()..start();
      var lastNotification = Duration.zero;
      await for (final chunk in request.timeout(const Duration(seconds: 45))) {
        await sink.writeFrom(chunk);
        record.transferredBytes += chunk.length;
        if (record.transferredBytes > record.totalBytes) {
          throw const FormatException('Received more bytes than declared.');
        }
        record.bytesPerSecond = stopwatch.elapsedMicroseconds == 0
            ? 0
            : record.transferredBytes *
                  Duration.microsecondsPerSecond /
                  stopwatch.elapsedMicroseconds;
        if (stopwatch.elapsed - lastNotification >=
            const Duration(milliseconds: 100)) {
          lastNotification = stopwatch.elapsed;
          _notifyListeners();
        }
      }
      await sink.close();
      sink = null;

      if (record.transferredBytes != record.totalBytes) {
        throw const FormatException(
          'The upload ended before all bytes arrived.',
        );
      }

      var savedPath = destination;
      if (_isAndroid()) {
        final published = await _androidDownloadPublisher.publish(
          source: partialFile,
          fileName: record.fileName,
        );
        record
          ..fileName = published.fileName
          ..savedPath = published.path;
        savedPath = published.path;
        _reservedDestinations.remove(destination);
        try {
          await partialFile.delete();
        } on FileSystemException catch (cleanupError, cleanupStackTrace) {
          _reportError(
            cleanupError,
            cleanupStackTrace,
            'Could not remove the temporary file after publishing its download.',
          );
        }
      }
      record
        ..status = TransferStatus.completed
        ..savedPath = savedPath;
      _reservedDestinations.remove(destination);
      _notifyListeners();
      await _writeJson(request.response, HttpStatus.created, {'saved': true});
      _trimRecords();
    } catch (error, stackTrace) {
      try {
        await sink?.close();
      } on FileSystemException catch (closeError, closeStackTrace) {
        _reportError(
          closeError,
          closeStackTrace,
          'Could not close the incomplete received file.',
        );
      }
      if (partialFile != null) {
        try {
          if (await partialFile.exists()) {
            await partialFile.delete();
          }
        } on FileSystemException catch (cleanupError, cleanupStackTrace) {
          _reportError(
            cleanupError,
            cleanupStackTrace,
            'Could not remove an incomplete received file.',
          );
        }
        _reservedDestinations.remove(partialFile.path);
      }
      record
        ..status = TransferStatus.failed
        ..errorMessage = error.toString()
        ..token = null;
      record.uploadTimer?.cancel();
      record.uploadTimer = null;
      _reportError(error, stackTrace, 'Could not save ${record.fileName}.');
      _notifyListeners();
      _trimRecords();
      await _writeJson(request.response, HttpStatus.internalServerError, {
        'error': 'تعذّر حفظ الملف بعد استقبال البيانات.',
      });
    }
  }

  Future<String> _ensureSaveDirectory() async {
    final cached = _saveDirectory;
    if (cached != null && !_isAndroid()) return cached;

    if (_isAndroid()) {
      final documentsDirectory = await _documentsDirectoryProvider();
      final stagingDirectory = Directory(
        '${documentsDirectory.path}${Platform.pathSeparator}Wasla'
        '${Platform.pathSeparator}.incoming',
      );
      await stagingDirectory.create(recursive: true);
      _saveDirectory = 'Downloads${Platform.pathSeparator}Wasla';
      return stagingDirectory.path;
    }

    Directory? directory;
    try {
      directory = await _downloadsDirectoryProvider();
    } on UnsupportedError {
      directory = null;
    }
    directory ??= await _documentsDirectoryProvider();

    final waslaDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}Wasla',
    );
    await waslaDirectory.create(recursive: true);
    _saveDirectory = waslaDirectory.path;
    return waslaDirectory.path;
  }

  Future<String> _availableDestination(
    String directory,
    String fileName,
  ) async {
    final separator = Platform.pathSeparator;
    final dot = fileName.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? fileName.substring(0, dot) : fileName;
    final extension = hasExtension ? fileName.substring(dot) : '';

    for (var index = 0; index < 10000; index++) {
      final suffix = index == 0 ? '' : ' ($index)';
      final candidate = File('$directory$separator$stem$suffix$extension');
      if (_reservedDestinations.contains(candidate.path)) continue;
      if (!await candidate.exists() &&
          !_reservedDestinations.contains(candidate.path)) {
        _reservedDestinations.add(candidate.path);
        return candidate.path;
      }
    }
    throw FileSystemException('Could not find a unique filename.', fileName);
  }

  Future<String> _readSmallBody(HttpRequest request) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in request) {
      length += chunk.length;
      if (length > _maxOfferBodyBytes) {
        throw const FormatException('Offer body is too large.');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<String> _readResponseBody(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > _maxOfferBodyBytes) {
        throw const FormatException(
          'The remote device returned an oversized response.',
        );
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(jsonEncode(body));
    await response.close();
  }

  String _selectAddress(DiscoveredDevice device) {
    final parsed = device.addresses
        .map((address) => InternetAddress.tryParse(address))
        .whereType<InternetAddress>()
        .toList();
    for (final address in parsed) {
      if (address.type == InternetAddressType.IPv4) return address.address;
    }
    for (final address in parsed) {
      if (address.type == InternetAddressType.IPv6 && !address.isLinkLocal) {
        return address.address;
      }
    }
    final hostname = device.hostname?.trim();
    if (hostname != null && hostname.isNotEmpty) {
      return hostname.endsWith('.')
          ? hostname.substring(0, hostname.length - 1)
          : hostname;
    }
    throw const SocketException('No usable network address was discovered.');
  }

  String _safeFileName(String input) {
    final leaf = input.replaceAll('\\', '/').split('/').last;
    var safe = leaf
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F]'), '_')
        .trim()
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..') safe = 'received-file';
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(safe)) {
      safe = '_$safe';
    }
    if (safe.length > 200) safe = safe.substring(0, 200);
    return safe;
  }

  String _readErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      return 'تعذّر إتمام نقل الملف.';
    }
    return 'تعذّر إتمام نقل الملف.';
  }

  String _randomHex(int byteCount) {
    final random = Random.secure();
    return List.generate(
      byteCount,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _trimRecords() {
    final completed =
        _records.values.where((record) => !record.snapshot.isActive).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    while (_records.length > 50 && completed.isNotEmpty) {
      _records.remove(completed.removeAt(0).id);
    }
  }

  void _reportError(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Wasla file transfer',
        context: ErrorDescription(context),
      ),
    );
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final record in _records.values) {
      record.uploadTimer?.cancel();
      final decision = record.decision;
      if (decision != null && !decision.isCompleted) {
        decision.complete(false);
      }
    }
    final server = _server;
    if (server != null) unawaited(_closeServer(server));
    _httpClient?.close(force: true);
    super.dispose();
  }

  Future<void> _closeServer(HttpServer server) async {
    try {
      await server.close(force: true);
    } on HttpException catch (error, stackTrace) {
      _reportError(error, stackTrace, 'Could not stop the local HTTP server.');
    } on SocketException catch (error, stackTrace) {
      _reportError(error, stackTrace, 'Could not stop the local HTTP server.');
    }
  }
}

class _TransferRecord {
  _TransferRecord({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.status,
    required this.totalBytes,
    required this.peerName,
  });

  final String id;
  String fileName;
  final TransferDirection direction;
  final int totalBytes;
  final String peerName;
  final DateTime createdAt = DateTime.now();
  int transferredBytes = 0;
  double bytesPerSecond = 0;
  TransferStatus status;
  String? errorMessage;
  String? savedPath;
  String? token;
  Completer<bool>? decision;
  Timer? uploadTimer;

  TransferSnapshot get snapshot => TransferSnapshot(
    id: id,
    fileName: fileName,
    direction: direction,
    status: status,
    totalBytes: totalBytes,
    transferredBytes: transferredBytes,
    bytesPerSecond: bytesPerSecond,
    peerName: peerName,
    errorMessage: errorMessage,
    savedPath: savedPath,
    createdAt: createdAt,
  );
}
