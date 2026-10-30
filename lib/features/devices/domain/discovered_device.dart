class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.platform,
    required this.addresses,
    required this.port,
    required this.isResolved,
    this.name = '',
    this.hostname,
    this.resolutionFailed = false,
  });

  final String id;
  final String platform;
  final String name;
  final String? hostname;
  final List<String> addresses;
  final int port;
  final bool isResolved;
  final bool resolutionFailed;

  bool get canConnect => addresses.isNotEmpty || hostname != null;

  DiscoveredDevice copyWith({
    String? name,
    String? hostname,
    List<String>? addresses,
    int? port,
    bool? isResolved,
    bool? resolutionFailed,
  }) => DiscoveredDevice(
    id: id,
    platform: platform,
    name: name ?? this.name,
    hostname: hostname ?? this.hostname,
    addresses: addresses ?? this.addresses,
    port: port ?? this.port,
    isResolved: isResolved ?? this.isResolved,
    resolutionFailed: resolutionFailed ?? this.resolutionFailed,
  );
}
