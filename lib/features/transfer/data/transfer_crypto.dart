import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class TransferCrypto {
  TransferCrypto._({
    required this.transferId,
    required this.transcript,
    required this.encryptionKey,
    required this.authenticationKey,
    required this.sasKey,
  });

  static const int chunkSize = 64 * 1024;
  static const int tagLength = 16;
  static const int frameOverhead = 4 + tagLength;

  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 96);
  static final _aes = AesGcm.with256bits();
  static final _hmac = Hmac.sha256();

  final String transferId;
  final Uint8List transcript;
  final Uint8List encryptionKey;
  final Uint8List authenticationKey;
  final Uint8List sasKey;

  static Future<SimpleKeyPair> createKeyPair() => _x25519.newKeyPair();

  static Uint8List createNonce() {
    final bytes = Uint8List(32);
    final random = Random.secure();
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    return bytes;
  }

  static String encodeBytes(List<int> bytes) => base64Url.encode(bytes);

  static Uint8List decodeBytes(String value, {int? expectedLength}) {
    final bytes = Uint8List.fromList(base64Url.decode(value));
    if (expectedLength != null && bytes.length != expectedLength) {
      throw const FormatException('Invalid cryptographic value length.');
    }
    return bytes;
  }

  static Future<TransferCrypto> derive({
    required String transferId,
    required SimpleKeyPair localKeyPair,
    required List<int> remotePublicKey,
    required List<int> senderPublicKey,
    required List<int> receiverPublicKey,
    required List<int> senderNonce,
    required List<int> receiverNonce,
  }) async {
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: SimplePublicKey(
        remotePublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final sharedSecretBytes = Uint8List.fromList(
      await sharedSecret.extractBytes(),
    );
    if (sharedSecretBytes.every((byte) => byte == 0)) {
      sharedSecretBytes.fillRange(0, sharedSecretBytes.length, 0);
      throw const FormatException('Invalid X25519 shared secret.');
    }
    final transcript = Uint8List.fromList([
      ...utf8.encode('Wasla transfer v2\u0000'),
      ...utf8.encode(transferId),
      ...senderPublicKey,
      ...receiverPublicKey,
      ...senderNonce,
      ...receiverNonce,
    ]);
    late final Uint8List bytes;
    try {
      final material = await _hkdf.deriveKey(
        secretKey: SecretKey(sharedSecretBytes),
        nonce: [...senderNonce, ...receiverNonce],
        info: transcript,
      );
      bytes = Uint8List.fromList(await material.extractBytes());
    } finally {
      sharedSecretBytes.fillRange(0, sharedSecretBytes.length, 0);
    }
    final encryptionKey = Uint8List.fromList(bytes.sublist(0, 32));
    final authenticationKey = Uint8List.fromList(bytes.sublist(32, 64));
    final sasKey = Uint8List.fromList(bytes.sublist(64, 96));
    bytes.fillRange(0, bytes.length, 0);
    return TransferCrypto._(
      transferId: transferId,
      transcript: transcript,
      encryptionKey: encryptionKey,
      authenticationKey: authenticationKey,
      sasKey: sasKey,
    );
  }

  Future<String> get verificationCode async {
    final mac = await _hmac.calculateMac(
      transcript,
      secretKey: SecretKey(sasKey),
    );
    var value = 0;
    for (final byte in mac.bytes.take(4)) {
      value = (value << 8) | byte;
    }
    return (value % 1000000).toString().padLeft(6, '0');
  }

  Future<String> authorization({
    required String method,
    required String path,
    required int sequence,
    required List<int> body,
  }) async {
    final bodyHash = await Sha256().hash(body);
    final message = utf8.encode(
      '$method\n$path\n$sequence\n${encodeBytes(bodyHash.bytes)}',
    );
    final mac = await _hmac.calculateMac(
      message,
      secretKey: SecretKey(authenticationKey),
    );
    return 'Wasla ${encodeBytes(mac.bytes)}';
  }

  Future<String> acceptanceProof() async {
    final mac = await _hmac.calculateMac(
      utf8.encode('accepted\n$transferId'),
      secretKey: SecretKey(authenticationKey),
    );
    return encodeBytes(mac.bytes);
  }

  Future<bool> verifyAcceptanceProof(String proof) async {
    try {
      final actual = decodeBytes(proof, expectedLength: 32);
      final expected = decodeBytes(await acceptanceProof(), expectedLength: 32);
      return constantTimeEquals(actual, expected);
    } on FormatException {
      return false;
    }
  }

  Future<String> completionProof(int totalBytes) async {
    final mac = await _hmac.calculateMac(
      utf8.encode('completed\n$transferId\n$totalBytes'),
      secretKey: SecretKey(authenticationKey),
    );
    return encodeBytes(mac.bytes);
  }

  Future<bool> verifyCompletionProof(String proof, int totalBytes) async {
    try {
      final actual = decodeBytes(proof, expectedLength: 32);
      final expected = decodeBytes(
        await completionProof(totalBytes),
        expectedLength: 32,
      );
      return constantTimeEquals(actual, expected);
    } on FormatException {
      return false;
    }
  }

  Future<SecretBox> encryptMetadata(List<int> clearText) => _aes.encrypt(
    clearText,
    secretKey: SecretKey(encryptionKey),
    nonce: _nonce(0),
    aad: _metadataAad,
  );

  Future<Uint8List> decryptMetadata({
    required List<int> cipherText,
    required List<int> mac,
  }) async {
    final clearText = await _aes.decrypt(
      SecretBox(cipherText, nonce: _nonce(0), mac: Mac(mac)),
      secretKey: SecretKey(encryptionKey),
      aad: _metadataAad,
    );
    return Uint8List.fromList(clearText);
  }

  Future<SecretBox> encryptChunk(List<int> clearText, int index) =>
      _aes.encrypt(
        clearText,
        secretKey: SecretKey(encryptionKey),
        nonce: _nonce(index + 1),
        aad: _chunkAad(index, clearText.length),
      );

  Future<Uint8List> decryptChunk({
    required List<int> cipherText,
    required List<int> mac,
    required int index,
    required int clearTextLength,
  }) async {
    final clearText = await _aes.decrypt(
      SecretBox(cipherText, nonce: _nonce(index + 1), mac: Mac(mac)),
      secretKey: SecretKey(encryptionKey),
      aad: _chunkAad(index, clearTextLength),
    );
    return Uint8List.fromList(clearText);
  }

  Future<bool> verifyAuthorization({
    required String authorization,
    required String method,
    required String path,
    required int sequence,
    required List<int> body,
  }) async {
    final expected = await this.authorization(
      method: method,
      path: path,
      sequence: sequence,
      body: body,
    );
    return constantTimeEquals(
      utf8.encode(authorization),
      utf8.encode(expected),
    );
  }

  void destroy() {
    encryptionKey.fillRange(0, encryptionKey.length, 0);
    authenticationKey.fillRange(0, authenticationKey.length, 0);
    sasKey.fillRange(0, sasKey.length, 0);
  }

  Uint8List get _metadataAad =>
      Uint8List.fromList(utf8.encode('Wasla v2 metadata\u0000$transferId'));

  Uint8List _chunkAad(int index, int length) => Uint8List.fromList(
    utf8.encode('Wasla v2 chunk\u0000$transferId\u0000$index\u0000$length'),
  );

  Uint8List _nonce(int index) {
    final nonce = Uint8List(_aes.nonceLength);
    ByteData.sublistView(nonce).setUint64(4, index, Endian.big);
    return nonce;
  }

  static bool constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
