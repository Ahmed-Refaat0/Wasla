enum TransferDirection { incoming, outgoing }

enum TransferStatus {
  requesting,
  awaitingApproval,
  waitingForUpload,
  transferring,
  completed,
  rejected,
  failed,
  cancelled,
}

class TransferSnapshot {
  const TransferSnapshot({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.status,
    required this.totalBytes,
    required this.transferredBytes,
    required this.bytesPerSecond,
    required this.peerName,
    required this.createdAt,
    required this.canRemove,
    required this.isCancelling,
    required this.canCancel,
    this.errorMessage,
    this.savedPath,
    this.pairingCode,
  });

  final String id;
  final String fileName;
  final TransferDirection direction;
  final TransferStatus status;
  final int totalBytes;
  final int transferredBytes;
  final double bytesPerSecond;
  final String peerName;
  final DateTime createdAt;
  final bool canRemove;
  final bool isCancelling;
  final bool canCancel;
  final String? errorMessage;
  final String? savedPath;
  final String? pairingCode;

  double get progress => totalBytes == 0
      ? (status == TransferStatus.completed ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1).toDouble();

  bool get needsApproval =>
      direction == TransferDirection.incoming &&
      status == TransferStatus.awaitingApproval;

  bool get isActive => switch (status) {
    TransferStatus.requesting ||
    TransferStatus.awaitingApproval ||
    TransferStatus.waitingForUpload ||
    TransferStatus.transferring => true,
    _ => false,
  };
}
