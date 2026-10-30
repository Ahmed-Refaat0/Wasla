import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/transfer/data/transfer_crypto.dart';

void main() {
  test('rejects invalid all-zero X25519 public keys', () async {
    final keyPair = await TransferCrypto.createKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    await expectLater(
      TransferCrypto.derive(
        transferId: '0123456789abcdef0123456789abcdef',
        localKeyPair: keyPair,
        remotePublicKey: Uint8List(32),
        senderPublicKey: publicKey.bytes,
        receiverPublicKey: Uint8List(32),
        senderNonce: TransferCrypto.createNonce(),
        receiverNonce: TransferCrypto.createNonce(),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('both peers derive the same code and encrypt/decrypt chunks', () async {
    final senderPair = await TransferCrypto.createKeyPair();
    final receiverPair = await TransferCrypto.createKeyPair();
    final senderPublic = await senderPair.extractPublicKey();
    final receiverPublic = await receiverPair.extractPublicKey();
    final senderNonce = TransferCrypto.createNonce();
    final receiverNonce = TransferCrypto.createNonce();
    final sender = await TransferCrypto.derive(
      transferId: '0123456789abcdef0123456789abcdef',
      localKeyPair: senderPair,
      remotePublicKey: receiverPublic.bytes,
      senderPublicKey: senderPublic.bytes,
      receiverPublicKey: receiverPublic.bytes,
      senderNonce: senderNonce,
      receiverNonce: receiverNonce,
    );
    final receiver = await TransferCrypto.derive(
      transferId: '0123456789abcdef0123456789abcdef',
      localKeyPair: receiverPair,
      remotePublicKey: senderPublic.bytes,
      senderPublicKey: senderPublic.bytes,
      receiverPublicKey: receiverPublic.bytes,
      senderNonce: senderNonce,
      receiverNonce: receiverNonce,
    );
    addTearDown(sender.destroy);
    addTearDown(receiver.destroy);

    expect(await sender.verificationCode, await receiver.verificationCode);
    expect(await sender.verificationCode, matches(RegExp(r'^\d{6}$')));

    final metadata = utf8.encode('private-name-and-size');
    final encryptedMetadata = await sender.encryptMetadata(metadata);
    expect(
      TransferCrypto.encodeBytes(encryptedMetadata.cipherText),
      isNot(contains('private')),
    );
    expect(
      await receiver.decryptMetadata(
        cipherText: encryptedMetadata.cipherText,
        mac: encryptedMetadata.mac.bytes,
      ),
      metadata,
    );

    final clearText = utf8.encode('authenticated file chunk');
    final encrypted = await sender.encryptChunk(clearText, 0);
    final decrypted = await receiver.decryptChunk(
      cipherText: encrypted.cipherText,
      mac: encrypted.mac.bytes,
      index: 0,
      clearTextLength: clearText.length,
    );
    expect(decrypted, clearText);

    final alteredMac = List<int>.from(encrypted.mac.bytes)..[0] ^= 1;
    await expectLater(
      receiver.decryptChunk(
        cipherText: encrypted.cipherText,
        mac: alteredMac,
        index: 0,
        clearTextLength: clearText.length,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    final auth = await sender.authorization(
      method: 'PUT',
      path: '/v2/files/0123456789abcdef0123456789abcdef',
      sequence: 1,
      body: const [],
    );
    expect(
      await receiver.verifyAuthorization(
        authorization: auth,
        method: 'PUT',
        path: '/v2/files/0123456789abcdef0123456789abcdef',
        sequence: 1,
        body: const [],
      ),
      isTrue,
    );
    expect(
      await receiver.verifyAuthorization(
        authorization: auth,
        method: 'PUT',
        path: '/v2/files/another-id',
        sequence: 1,
        body: const [],
      ),
      isFalse,
    );
  });
}
