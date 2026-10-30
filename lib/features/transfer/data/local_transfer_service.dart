import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../devices/domain/discovered_device.dart';
import '../domain/transfer_file_source.dart';
import '../domain/transfer_snapshot.dart';
import 'android_download_publisher.dart';
import 'transfer_crypto.dart';

class LocalTransferService extends ChangeNotifier {
  static const int port = 53317;
  static const int maxFileSizeBytes = 50 * 1024 * 1024 * 1024;
  static const int _maxControlBodyBytes = 16 * 1024;
  static const int _maxPendingOffers = 4;
  static const Duration _offerTimeout = Duration(minutes: 2);
  static const int _chunkSize = TransferCrypto.chunkSize;

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
  final Map<String, _PendingHandshake> _handshakes = {};
  final Set<String> _handshakesBeingCreated = {};
  final Set<String> _reservedDestinations = {};
  final Map<String, int> _handshakeCreationsByPeer = {};
  int _handshakeCreations = 0;
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
    if (record.totalBytes < 0 || record.totalBytes > maxFileSizeBytes) {
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'الحد الأقصى لحجم الملف هو ٥٠ جيجابايت.';
      _records[record.id] = record;
      _notifyListeners();
      return;
    }

    _records[record.id] = record;
    _notifyListeners();
    TransferCrypto? crypto;
    try {
      final client = _httpClient;
      if (client == null) throw StateError('HTTP client is not available.');
      final baseUri = Uri(scheme: 'http', host: address, port: device.port);
      final keyPair = await TransferCrypto.createKeyPair();
      final senderPublicKey = await keyPair.extractPublicKey();
      final senderNonce = TransferCrypto.createNonce();
      final handshakeBody = utf8.encode(
        jsonEncode({
          'id': record.id,
          'publicKey': TransferCrypto.encodeBytes(senderPublicKey.bytes),
          'nonce': TransferCrypto.encodeBytes(senderNonce),
        }),
      );
      final handshakeResponse = await _postBytes(
        client,
        baseUri.replace(path: '/v2/handshakes'),
        handshakeBody,
      );
      if (handshakeResponse.statusCode != HttpStatus.ok) {
        throw HttpException(
          _readErrorMessage(await _readResponseBody(handshakeResponse)),
          uri: baseUri,
        );
      }

      final handshake = jsonDecode(await _readResponseBody(handshakeResponse));
      if (handshake is! Map<String, dynamic> ||
          handshake['publicKey'] is! String ||
          handshake['nonce'] is! String) {
        throw const FormatException(
          'The receiving device returned an invalid security handshake.',
        );
      }
      final receiverPublicKey = TransferCrypto.decodeBytes(
        handshake['publicKey'] as String,
        expectedLength: 32,
      );
      final receiverNonce = TransferCrypto.decodeBytes(
        handshake['nonce'] as String,
        expectedLength: 32,
      );
      crypto = await TransferCrypto.derive(
        transferId: record.id,
        localKeyPair: keyPair,
        remotePublicKey: receiverPublicKey,
        senderPublicKey: senderPublicKey.bytes,
        receiverPublicKey: receiverPublicKey,
        senderNonce: senderNonce,
        receiverNonce: receiverNonce,
      );
      record.pairingCode = await crypto.verificationCode;
      _notifyListeners();

      final metadata = utf8.encode(
        jsonEncode({
          'name': record.fileName,
          'size': record.totalBytes,
          'sender': Platform.operatingSystem,
        }),
      );
      final encryptedMetadata = await crypto.encryptMetadata(metadata);
      final offerBody = utf8.encode(
        jsonEncode({
          'id': record.id,
          'cipherText': TransferCrypto.encodeBytes(
            encryptedMetadata.cipherText,
          ),
          'mac': TransferCrypto.encodeBytes(encryptedMetadata.mac.bytes),
        }),
      );
      const offerPath = '/v2/offers';
      final offerRequest = await client.postUrl(
        baseUri.replace(path: offerPath),
      );
      offerRequest.headers.contentType = ContentType.json;
      offerRequest.headers.set(
        HttpHeaders.authorizationHeader,
        await crypto.authorization(
          method: 'POST',
          path: offerPath,
          sequence: 0,
          body: offerBody,
        ),
      );
      offerRequest.add(offerBody);
      final offerResponse = await offerRequest.close();
      final offerResponseBody = await _readResponseBody(offerResponse);
      if (offerResponse.statusCode != HttpStatus.ok) {
        throw HttpException(_readErrorMessage(offerResponseBody), uri: baseUri);
      }
      final offerResult = jsonDecode(offerResponseBody);
      if (offerResult is! Map<String, dynamic> ||
          offerResult['proof'] is! String ||
          !await crypto.verifyAcceptanceProof(offerResult['proof'] as String)) {
        throw const FormatException(
          'The receiver acceptance could not be authenticated.',
        );
      }

      record.status = TransferStatus.transferring;
      _notifyListeners();
      final uploadPath = '/v2/files/${record.id}';
      final uploadRequest = await client.putUrl(
        baseUri.replace(path: uploadPath),
      );
      uploadRequest.headers.contentType = ContentType.binary;
      uploadRequest.headers.set(
        HttpHeaders.authorizationHeader,
        await crypto.authorization(
          method: 'PUT',
          path: uploadPath,
          sequence: 1,
          body: const [],
        ),
      );
      final frameCount = (record.totalBytes + _chunkSize - 1) ~/ _chunkSize;
      uploadRequest.contentLength =
          record.totalBytes + frameCount * TransferCrypto.frameOverhead;
      final stopwatch = Stopwatch()..start();
      var lastNotification = Duration.zero;
      await uploadRequest.addStream(
        _encryptedChunks(
          source,
          crypto,
          record,
          stopwatch,
          onProgress: () {
            if (stopwatch.elapsed - lastNotification >=
                const Duration(milliseconds: 100)) {
              lastNotification = stopwatch.elapsed;
              _notifyListeners();
            }
          },
        ),
      );

      final uploadResponse = await uploadRequest.close();
      final responseBody = await _readResponseBody(uploadResponse);
      if (uploadResponse.statusCode != HttpStatus.created) {
        throw HttpException(_readErrorMessage(responseBody), uri: baseUri);
      }
      final uploadResult = jsonDecode(responseBody);
      if (uploadResult is! Map<String, dynamic> ||
          uploadResult['proof'] is! String ||
          !await crypto.verifyCompletionProof(
            uploadResult['proof'] as String,
            record.totalBytes,
          )) {
        throw const FormatException(
          'The receiver completion could not be authenticated.',
        );
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
    } finally {
      crypto?.destroy();
    }
  }

  Stream<List<int>> _encryptedChunks(
    TransferFileSource source,
    TransferCrypto crypto,
    _TransferRecord record,
    Stopwatch stopwatch, {
    required VoidCallback onProgress,
  }) async* {
    final pending = BytesBuilder(copy: false);
    var sourceBytes = 0;
    var index = 0;

    Future<Uint8List> encodeFrame(List<int> clearText) async {
      final box = await crypto.encryptChunk(clearText, index++);
      final frame = Uint8List(4 + box.cipherText.length + box.mac.bytes.length);
      ByteData.sublistView(
        frame,
      ).setUint32(0, box.cipherText.length + box.mac.bytes.length, Endian.big);
      frame.setRange(4, 4 + box.cipherText.length, box.cipherText);
      frame.setRange(4 + box.cipherText.length, frame.length, box.mac.bytes);
      record.transferredBytes += clearText.length;
      record.bytesPerSecond = stopwatch.elapsedMicroseconds == 0
          ? 0
          : record.transferredBytes *
                Duration.microsecondsPerSecond /
                stopwatch.elapsedMicroseconds;
      onProgress();
      return frame;
    }

    await for (final bytes in source.openRead()) {
      sourceBytes += bytes.length;
      if (sourceBytes > source.size) {
        throw const FormatException(
          'Source returned more bytes than declared.',
        );
      }
      final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      var offset = 0;
      if (pending.length > 0) {
        final needed = _chunkSize - pending.length;
        final take = min(needed, input.length);
        pending.add(input.sublist(0, take));
        offset = take;
        if (pending.length == _chunkSize) {
          yield await encodeFrame(pending.takeBytes());
        }
      }
      while (offset + _chunkSize <= input.length) {
        yield await encodeFrame(
          Uint8List.sublistView(input, offset, offset + _chunkSize),
        );
        offset += _chunkSize;
      }
      if (offset < input.length) pending.add(input.sublist(offset));
    }
    if (sourceBytes != source.size) {
      throw const FormatException('Source ended before its declared length.');
    }
    if (pending.length > 0) yield await encodeFrame(pending.takeBytes());
  }

  void accept(String transferId) {
    final record = _records[transferId];
    if (record == null ||
        record.status != TransferStatus.awaitingApproval ||
        record.decision == null ||
        record.crypto == null) {
      return;
    }
    record.status = TransferStatus.waitingForUpload;
    record.uploadTimer = Timer(_offerTimeout, () {
      if (record.status != TransferStatus.waitingForUpload) return;
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'انتهت مهلة بدء إرسال الملف.'
        ..uploadTimer = null;
      record.crypto?.destroy();
      record.crypto = null;
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
      ..decision!.complete(false);
    record.crypto?.destroy();
    record.crypto = null;
    _notifyListeners();
    _trimRecords();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/v2/handshakes') {
        await _handleHandshake(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v2/offers') {
        await _handleOffer(request);
        return;
      }
      if (request.method == 'PUT' &&
          request.uri.pathSegments.length == 3 &&
          request.uri.pathSegments[0] == 'v2' &&
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
        request.response.persistentConnection = false;
        await _writeJson(request.response, HttpStatus.badRequest, {
          'error': 'تعذّر معالجة طلب النقل الآمن.',
        });
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
      } on SocketException catch (closeError, closeStackTrace) {
        _reportError(
          closeError,
          closeStackTrace,
          'Could not close the failed HTTP response.',
        );
      }
    }
  }

  Future<void> _handleHandshake(HttpRequest request) async {
    final body = await _readLimitedRequest(request, _maxControlBodyBytes);
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic> ||
        decoded['id'] is! String ||
        decoded['publicKey'] is! String ||
        decoded['nonce'] is! String) {
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات المصافحة غير صالحة.',
      });
      return;
    }

    final id = decoded['id'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        _records.containsKey(id) ||
        _handshakes.containsKey(id) ||
        _handshakesBeingCreated.contains(id)) {
      await _writeJson(request.response, HttpStatus.conflict, {
        'error': 'معرّف المصافحة غير صالح أو مستخدم بالفعل.',
      });
      return;
    }
    final activeTransfers = _records.values
        .where((record) => record.snapshot.isActive)
        .length;
    if (_handshakes.length + _handshakeCreations + activeTransfers >=
        _maxPendingOffers) {
      await _writeJson(request.response, HttpStatus.tooManyRequests, {
        'error': 'هناك طلبات نقل معلّقة كثيرة؛ حاول لاحقًا.',
      });
      return;
    }
    final peerAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final creatingFromPeer = _handshakeCreationsByPeer[peerAddress] ?? 0;
    final pendingFromPeer = _handshakes.values
        .where((handshake) => handshake.peerAddress == peerAddress)
        .length;
    if (creatingFromPeer + pendingFromPeer >= 2) {
      await _writeJson(request.response, HttpStatus.tooManyRequests, {
        'error': 'يوجد عدد كبير من طلبات المصافحة من هذا الجهاز.',
      });
      return;
    }

    final senderPublicKey = TransferCrypto.decodeBytes(
      decoded['publicKey'] as String,
      expectedLength: 32,
    );
    final senderNonce = TransferCrypto.decodeBytes(
      decoded['nonce'] as String,
      expectedLength: 32,
    );
    _handshakeCreations++;
    _handshakesBeingCreated.add(id);
    _handshakeCreationsByPeer.update(
      peerAddress,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    try {
      final keyPair = await TransferCrypto.createKeyPair();
      final receiverPublicKey = await keyPair.extractPublicKey();
      final receiverNonce = TransferCrypto.createNonce();
      final crypto = await TransferCrypto.derive(
        transferId: id,
        localKeyPair: keyPair,
        remotePublicKey: senderPublicKey,
        senderPublicKey: senderPublicKey,
        receiverPublicKey: receiverPublicKey.bytes,
        senderNonce: senderNonce,
        receiverNonce: receiverNonce,
      );
      final pending = _PendingHandshake(
        id: id,
        crypto: crypto,
        peerAddress: peerAddress,
      );
      pending.timer = Timer(_offerTimeout, () {
        if (identical(_handshakes[id], pending)) {
          _handshakes.remove(id);
          crypto.destroy();
        }
      });
      _handshakes[id] = pending;
      await _writeJson(request.response, HttpStatus.ok, {
        'publicKey': TransferCrypto.encodeBytes(receiverPublicKey.bytes),
        'nonce': TransferCrypto.encodeBytes(receiverNonce),
      });
    } finally {
      _handshakeCreations--;
      _handshakesBeingCreated.remove(id);
      final remaining = (_handshakeCreationsByPeer[peerAddress] ?? 1) - 1;
      if (remaining == 0) {
        _handshakeCreationsByPeer.remove(peerAddress);
      } else {
        _handshakeCreationsByPeer[peerAddress] = remaining;
      }
    }
  }

  Future<void> _handleOffer(HttpRequest request) async {
    final body = await _readLimitedRequest(request, _maxControlBodyBytes);
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic> ||
        decoded['id'] is! String ||
        decoded['cipherText'] is! String ||
        decoded['mac'] is! String) {
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات طلب النقل غير صالحة.',
      });
      return;
    }

    final id = decoded['id'] as String;
    final pending = _handshakes[id];
    if (pending == null) {
      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'جلسة المصافحة غير موجودة أو انتهت.',
      });
      return;
    }
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (authorization == null ||
        !await pending.crypto.verifyAuthorization(
          authorization: authorization,
          method: 'POST',
          path: '/v2/offers',
          sequence: 0,
          body: body,
        )) {
      await _writeJson(request.response, HttpStatus.unauthorized, {
        'error': 'تعذّر التحقق من طلب النقل.',
      });
      return;
    }
    if (!identical(_handshakes[id], pending) || pending.claimed) {
      await _writeJson(request.response, HttpStatus.conflict, {
        'error': 'تم استخدام طلب النقل بالفعل أو انتهت صلاحيته.',
      });
      return;
    }
    pending
      ..claimed = true
      ..timer?.cancel();

    Uint8List clearText;
    Map<String, dynamic> metadata;
    try {
      final cipherText = TransferCrypto.decodeBytes(
        decoded['cipherText'] as String,
      );
      final mac = TransferCrypto.decodeBytes(
        decoded['mac'] as String,
        expectedLength: TransferCrypto.tagLength,
      );
      clearText = await pending.crypto.decryptMetadata(
        cipherText: cipherText,
        mac: mac,
      );
      final decodedMetadata = jsonDecode(utf8.decode(clearText));
      if (decodedMetadata is! Map<String, dynamic> ||
          decodedMetadata['name'] is! String ||
          decodedMetadata['size'] is! int ||
          decodedMetadata['sender'] is! String ||
          (decodedMetadata['size'] as int) < 0 ||
          (decodedMetadata['size'] as int) > maxFileSizeBytes) {
        throw const FormatException('Invalid encrypted transfer metadata.');
      }
      metadata = decodedMetadata;
    } on SecretBoxAuthenticationError {
      _handshakes.remove(id);
      pending.crypto.destroy();
      await _writeJson(request.response, HttpStatus.unauthorized, {
        'error': 'تعذّر التحقق من تشفير بيانات النقل.',
      });
      return;
    } on FormatException {
      _handshakes.remove(id);
      pending.crypto.destroy();
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'بيانات الملف غير مكتملة أو حجم الملف غير مقبول.',
      });
      return;
    }

    final pairingCode = await pending.crypto.verificationCode;
    _handshakes.remove(id);
    final record = _TransferRecord(
      id: id,
      fileName: _safeFileName(metadata['name'] as String),
      direction: TransferDirection.incoming,
      status: TransferStatus.awaitingApproval,
      totalBytes: metadata['size'] as int,
      peerName: metadata['sender'] as String,
      pairingCode: pairingCode,
      crypto: pending.crypto,
    )..decision = Completer<bool>();
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
          ..errorMessage = 'انتهت مهلة الموافقة على طلب الاستقبال.';
        record.crypto?.destroy();
        record.crypto = null;
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

    await _writeJson(request.response, HttpStatus.ok, {
      'proof': await pending.crypto.acceptanceProof(),
    });
  }

  Future<void> _handleUpload(HttpRequest request, String id) async {
    final record = _records[id];
    final crypto = record?.crypto;
    if (record == null ||
        crypto == null ||
        record.direction != TransferDirection.incoming ||
        record.status != TransferStatus.waitingForUpload) {
      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'طلب استقبال الملف غير موجود أو لم تتم الموافقة عليه.',
      });
      return;
    }

    final path = '/v2/files/$id';
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final authorized =
        authorization != null &&
        await crypto.verifyAuthorization(
          authorization: authorization,
          method: 'PUT',
          path: path,
          sequence: 1,
          body: const [],
        );
    if (!authorized) {
      await _writeJson(request.response, HttpStatus.unauthorized, {
        'error': 'رمز التحقق لطلب النقل غير صالح.',
      });
      return;
    }
    if (record.status != TransferStatus.waitingForUpload ||
        record.crypto != crypto) {
      await _writeJson(request.response, HttpStatus.conflict, {
        'error': 'تم استخدام طلب النقل بالفعل.',
      });
      return;
    }

    final frameCount = (record.totalBytes + _chunkSize - 1) ~/ _chunkSize;
    final expectedLength =
        record.totalBytes + frameCount * TransferCrypto.frameOverhead;
    if (request.contentLength != expectedLength) {
      request.response.persistentConnection = false;
      await _writeJson(request.response, HttpStatus.badRequest, {
        'error': 'حجم الملف المشفر لا يطابق البيانات المعلنة.',
      });
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'حجم الملف المشفر لا يطابق البيانات المعلنة.';
      crypto.destroy();
      record.crypto = null;
      _notifyListeners();
      return;
    }

    record.uploadTimer?.cancel();
    record.uploadTimer = null;
    record.status = TransferStatus.transferring;
    _notifyListeners();

    File? partialFile;
    RandomAccessFile? sink;
    String? reservedDestination;
    var committed = false;
    try {
      final directory = await _ensureSaveDirectory();
      reservedDestination = await _availableDestination(
        directory,
        record.fileName,
      );
      partialFile = File(
        '$directory${Platform.pathSeparator}.wasla-${record.id}.part',
      );
      await partialFile.create(exclusive: true);
      sink = await partialFile.open(mode: FileMode.writeOnly);
      final stopwatch = Stopwatch()..start();
      var lastNotification = Duration.zero;
      final reader = _ByteStreamReader(
        request.timeout(const Duration(seconds: 45)),
      );
      var receivedBytes = 0;
      var index = 0;
      try {
        while (receivedBytes < record.totalBytes) {
          final header = await reader.readExactly(4);
          final frameLength = ByteData.sublistView(header)
              .getUint32(0, Endian.big);
          final plainLength = min(
            _chunkSize,
            record.totalBytes - receivedBytes,
          );
          if (frameLength != plainLength + TransferCrypto.tagLength) {
            throw const FormatException('Invalid encrypted chunk frame.');
          }
          final frame = await reader.readExactly(frameLength);
          final clearText = await crypto.decryptChunk(
            cipherText: frame.sublist(0, plainLength),
            mac: frame.sublist(plainLength),
            index: index++,
            clearTextLength: plainLength,
          );
          await sink.writeFrom(clearText);
          receivedBytes += clearText.length;
          record.transferredBytes = receivedBytes;
          record.bytesPerSecond = stopwatch.elapsedMicroseconds == 0
              ? 0
              : receivedBytes *
                    Duration.microsecondsPerSecond /
                    stopwatch.elapsedMicroseconds;
          if (stopwatch.elapsed - lastNotification >=
              const Duration(milliseconds: 100)) {
            lastNotification = stopwatch.elapsed;
            _notifyListeners();
          }
        }
        if (await reader.hasMore) {
          throw const FormatException('Unexpected trailing encrypted data.');
        }
      } finally {
        await reader.cancel();
      }
      await sink.close();
      sink = null;
      final proof = await crypto.completionProof(record.totalBytes);

      var savedPath = reservedDestination;
      if (_isAndroid()) {
        final published = await _androidDownloadPublisher.publish(
          source: partialFile,
          fileName: record.fileName,
        );
        record
          ..fileName = published.fileName
          ..savedPath = published.path
          ..status = TransferStatus.completed;
        savedPath = published.path;
        committed = true;
        try {
          await partialFile.delete();
        } on FileSystemException catch (cleanupError, cleanupStackTrace) {
          _reportError(
            cleanupError,
            cleanupStackTrace,
            'Could not remove the staging file after publishing the download.',
          );
        }
      } else {
        await partialFile.rename(reservedDestination);
        committed = true;
        record.status = TransferStatus.completed;
      }

      record.savedPath = savedPath;
      record.uploadTimer?.cancel();
      record.uploadTimer = null;
      crypto.destroy();
      record.crypto = null;
      _reservedDestinations.remove(reservedDestination);
      _notifyListeners();
      await _writeJson(request.response, HttpStatus.created, {'proof': proof});
      _trimRecords();
    } catch (error, stackTrace) {
      if (committed) {
        _reportError(
          error,
          stackTrace,
          'The receiver could not finish the transfer response.',
        );
        return;
      }
      try {
        await sink?.close();
      } on FileSystemException catch (closeError, closeStackTrace) {
        _reportError(
          closeError,
          closeStackTrace,
          'Could not close partial file.',
        );
      }
      if (partialFile != null) {
        try {
          if (await partialFile.exists()) await partialFile.delete();
        } on FileSystemException catch (cleanupError, cleanupStackTrace) {
          _reportError(
            cleanupError,
            cleanupStackTrace,
            'Could not remove an incomplete received file.',
          );
        }
      }
      if (reservedDestination != null) {
        _reservedDestinations.remove(reservedDestination);
      }
      record
        ..status = TransferStatus.failed
        ..errorMessage = 'تعذّر حفظ الملف بعد استقبال البيانات.';
      record.uploadTimer?.cancel();
      record.uploadTimer = null;
      crypto.destroy();
      record.crypto = null;
      _reportError(error, stackTrace, 'Could not save ${record.fileName}.');
      _notifyListeners();
      _trimRecords();
      await _writeJson(request.response, HttpStatus.internalServerError, {
        'error': 'تعذّر حفظ الملف بعد استقبال البيانات.',
      });
    }
  }

  Future<HttpClientResponse> _postBytes(
    HttpClient client,
    Uri uri,
    List<int> body,
  ) async {
    final request = await client.postUrl(uri);
    request
      ..headers.contentType = ContentType.json
      ..contentLength = body.length
      ..add(body);
    return request.close();
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

  Future<Uint8List> _readLimitedRequest(
    HttpRequest request,
    int maximumBytes,
  ) async {
    if (request.contentLength > maximumBytes) {
      request.response.persistentConnection = false;
      throw const FormatException('Request body exceeds its allowed size.');
    }
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in request) {
      length += chunk.length;
      if (length > maximumBytes) {
        request.response.persistentConnection = false;
        throw const FormatException('Request body exceeds its allowed size.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<String> _readResponseBody(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > _maxControlBodyBytes) {
        throw const FormatException('Remote response is too large.');
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
    for (final pending in _handshakes.values) {
      pending.timer?.cancel();
      pending.crypto.destroy();
    }
    _handshakes.clear();
    for (final record in _records.values) {
      record.uploadTimer?.cancel();
      record.crypto?.destroy();
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

class _PendingHandshake {
  _PendingHandshake({
    required this.id,
    required this.crypto,
    required this.peerAddress,
  });

  final String id;
  final TransferCrypto crypto;
  final String peerAddress;
  Timer? timer;
  bool claimed = false;
}

class _TransferRecord {
  _TransferRecord({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.status,
    required this.totalBytes,
    required this.peerName,
    this.pairingCode,
    this.crypto,
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
  String? pairingCode;
  TransferCrypto? crypto;
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
    pairingCode: pairingCode,
    createdAt: createdAt,
  );
}

class _ByteStreamReader {
  _ByteStreamReader(Stream<List<int>> stream)
    : _iterator = StreamIterator(stream);

  final StreamIterator<List<int>> _iterator;
  List<int> _current = const [];
  int _offset = 0;

  Future<Uint8List> readExactly(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _current.length) {
        if (!await _iterator.moveNext()) {
          throw const FormatException('Encrypted upload ended unexpectedly.');
        }
        _current = _iterator.current;
        _offset = 0;
      }
      final count = min(length - written, _current.length - _offset);
      result.setRange(written, written + count, _current, _offset);
      written += count;
      _offset += count;
    }
    return result;
  }

  Future<bool> get hasMore async {
    while (_offset >= _current.length) {
      if (!await _iterator.moveNext()) return false;
      _current = _iterator.current;
      _offset = 0;
    }
    return true;
  }

  Future<void> cancel() => _iterator.cancel();
}
