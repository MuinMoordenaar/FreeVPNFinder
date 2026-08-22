enum ConnectionMode { vpn, systemProxy, proxyOnly }

extension ConnectionModeLabel on ConnectionMode {
  String get label => switch (this) {
    ConnectionMode.vpn => 'VPN',
    ConnectionMode.systemProxy => 'System Proxy',
    ConnectionMode.proxyOnly => 'Proxy Only',
  };
}

enum AppPhase {
  disconnected,
  updatingSources,
  searching,
  connecting,
  verifying,
  connected,
  degraded,
  switching,
  disconnecting,
  error,
}

enum NodeState { unknown, checking, working, failed, cooldown, active, standby }

class VpnNode {
  VpnNode({
    required this.id,
    required this.fingerprint,
    required this.sourceId,
    required this.protocol,
    required this.host,
    required this.port,
    required this.name,
    required this.rawConfiguration,
    required this.options,
    this.country = 'Unknown',
    this.latency,
    this.averageLatency,
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastCheckedAt,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.state = NodeState.unknown,
  });

  final String id,
      fingerprint,
      sourceId,
      protocol,
      host,
      name,
      country,
      rawConfiguration;
  final int port;
  final Map<String, dynamic> options;
  int? latency;
  double? averageLatency;
  int successCount, failureCount, consecutiveFailures;
  DateTime? lastCheckedAt, lastSuccessAt, lastFailureAt;
  NodeState state;

  double get score {
    final total = successCount + failureCount;
    final reliability = total == 0 ? .55 : successCount / total;
    final speed = latency == null ? .25 : 1 - latency!.clamp(0, 2000) / 2000;
    return reliability * 70 + speed * 30 - consecutiveFailures * 8;
  }

  void recordSuccess(int value) {
    latency = value;
    averageLatency = averageLatency == null
        ? value.toDouble()
        : averageLatency! * .75 + value * .25;
    successCount++;
    consecutiveFailures = 0;
    lastCheckedAt = lastSuccessAt = DateTime.now();
    state = NodeState.working;
  }

  void recordFailure() {
    failureCount++;
    consecutiveFailures++;
    lastCheckedAt = lastFailureAt = DateTime.now();
    state = consecutiveFailures >= 3 ? NodeState.cooldown : NodeState.failed;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'fingerprint': fingerprint,
    'sourceId': sourceId,
    'protocol': protocol,
    'host': host,
    'port': port,
    'name': name,
    'country': country,
    'rawConfiguration': rawConfiguration,
    'options': options,
    'latency': latency,
    'averageLatency': averageLatency,
    'successCount': successCount,
    'failureCount': failureCount,
    'consecutiveFailures': consecutiveFailures,
    'lastCheckedAt': lastCheckedAt?.toIso8601String(),
    'lastSuccessAt': lastSuccessAt?.toIso8601String(),
    'lastFailureAt': lastFailureAt?.toIso8601String(),
    'state': state.name,
  };

  factory VpnNode.fromJson(Map<String, dynamic> j) => VpnNode(
    id: j['id'],
    fingerprint: j['fingerprint'],
    sourceId: j['sourceId'],
    protocol: j['protocol'],
    host: j['host'],
    port: j['port'],
    name: j['name'] ?? 'Unnamed node',
    country: j['country'] ?? 'Unknown',
    rawConfiguration: j['rawConfiguration'],
    options: Map<String, dynamic>.from(j['options'] ?? {}),
    latency: j['latency'],
    averageLatency: (j['averageLatency'] as num?)?.toDouble(),
    successCount: j['successCount'] ?? 0,
    failureCount: j['failureCount'] ?? 0,
    consecutiveFailures: j['consecutiveFailures'] ?? 0,
    lastCheckedAt: DateTime.tryParse(j['lastCheckedAt'] ?? ''),
    lastSuccessAt: DateTime.tryParse(j['lastSuccessAt'] ?? ''),
    lastFailureAt: DateTime.tryParse(j['lastFailureAt'] ?? ''),
    state:
        NodeState.values.where((e) => e.name == j['state']).firstOrNull ??
        NodeState.unknown,
  );
}

class VpnSource {
  const VpnSource({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.custom = false,
  });
  final String id, name, url;
  final bool enabled, custom;
  VpnSource copyWith({bool? enabled}) => VpnSource(
    id: id,
    name: name,
    url: url,
    enabled: enabled ?? this.enabled,
    custom: custom,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    'custom': custom,
  };
  factory VpnSource.fromJson(Map<String, dynamic> j) => VpnSource(
    id: j['id'],
    name: j['name'],
    url: j['url'],
    enabled: j['enabled'] ?? true,
    custom: j['custom'] ?? false,
  );
}

class AppSettings {
  AppSettings({
    this.mode = ConnectionMode.systemProxy,
    this.autoQualityFailover = true,
    this.qualityLatencyMs = 800,
    this.failureThreshold = 3,
    this.failoverCooldownSeconds = 300,
    this.healthIntervalSeconds = 15,
    this.backupPoolSize = 10,
    this.backupProbeIntervalSeconds = 5,
    this.startMinimized = false,
  });
  ConnectionMode mode;
  bool autoQualityFailover, startMinimized;
  int qualityLatencyMs,
      failureThreshold,
      failoverCooldownSeconds,
      healthIntervalSeconds,
      backupPoolSize,
      backupProbeIntervalSeconds;
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'autoQualityFailover': autoQualityFailover,
    'qualityLatencyMs': qualityLatencyMs,
    'failureThreshold': failureThreshold,
    'failoverCooldownSeconds': failoverCooldownSeconds,
    'healthIntervalSeconds': healthIntervalSeconds,
    'backupPoolSize': backupPoolSize,
    'backupProbeIntervalSeconds': backupProbeIntervalSeconds,
    'startMinimized': startMinimized,
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    mode:
        ConnectionMode.values.where((e) => e.name == j['mode']).firstOrNull ??
        ConnectionMode.systemProxy,
    autoQualityFailover: j['autoQualityFailover'] ?? true,
    qualityLatencyMs: j['qualityLatencyMs'] ?? 800,
    failureThreshold: j['failureThreshold'] ?? 3,
    failoverCooldownSeconds: j['failoverCooldownSeconds'] ?? 300,
    healthIntervalSeconds: j['healthIntervalSeconds'] ?? 15,
    backupPoolSize: ((j['backupPoolSize'] as num?) ?? 10).clamp(3, 15).toInt(),
    backupProbeIntervalSeconds: ((j['backupProbeIntervalSeconds'] as num?) ?? 5)
        .clamp(1, 25)
        .toInt(),
    startMinimized: j['startMinimized'] ?? false,
  );
}
