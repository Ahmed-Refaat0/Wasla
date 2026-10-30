import 'dart:io';

import 'package:flutter/services.dart';

class AndroidDownloadPublisher {
  AndroidDownloadPublisher({
    this._channel = const MethodChannel('wasla/downloads'),
  });

  final MethodChannel _channel;

  Future<AndroidDownloadLocation> publish({
    required File source,
    required String fileName,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'publishDownload',
      {'sourcePath': source.path, 'fileName': fileName},
    );
    final savedPath = result?['path'];
    final savedName = result?['fileName'];
    if (savedPath is! String ||
        savedPath.isEmpty ||
        savedName is! String ||
        savedName.isEmpty) {
      throw const FormatException(
        'Android did not return the saved Downloads location.',
      );
    }
    return AndroidDownloadLocation(path: savedPath, fileName: savedName);
  }
}

class AndroidDownloadLocation {
  const AndroidDownloadLocation({required this.path, required this.fileName});

  final String path;
  final String fileName;
}
