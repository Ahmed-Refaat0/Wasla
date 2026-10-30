class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.platform,
    required this.addresses,
    required this.port,
    required this.isResolved,
  });
  final String id;
  final String platform;
  final List<String> addresses;
  final int port;
  final bool isResolved;
}
