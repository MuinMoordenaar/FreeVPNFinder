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

enum SplitTunnelMode { bypass, vpnOnly }

class SplitTunnelApp {
  SplitTunnelApp({required this.name, required this.path, this.enabled = true});
  final String name;
  final String path;
  bool enabled;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'enabled': enabled,
  };

  factory SplitTunnelApp.fromJson(Map<String, dynamic> json) => SplitTunnelApp(
    name: json['name'] is String ? json['name'] as String : 'Application',
    path: json['path'] is String ? json['path'] as String : '',
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
  );
}

class SplitTunnelSettings {
  SplitTunnelSettings({
    this.enabled = false,
    this.mode = SplitTunnelMode.bypass,
    List<SplitTunnelApp>? applications,
    List<String>? domains,
  }) : applications = applications ?? [],
       domains = domains ?? [];

  bool enabled;
  SplitTunnelMode mode;
  final List<SplitTunnelApp> applications;
  final List<String> domains;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'mode': mode.name,
    'applications': applications.map((e) => e.toJson()).toList(),
    'domains': domains,
  };

  factory SplitTunnelSettings.fromJson(Map<String, dynamic> json) {
    final rawApplications = json['applications'];
    final rawDomains = json['domains'];
    return SplitTunnelSettings(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
      mode:
          SplitTunnelMode.values.where((value) {
            return value.name == json['mode'];
          }).firstOrNull ??
          SplitTunnelMode.bypass,
      applications: [
        if (rawApplications is List)
          for (final item in rawApplications)
            if (item is Map)
              SplitTunnelApp.fromJson(Map<String, dynamic>.from(item)),
      ],
      domains: [
        if (rawDomains is List)
          for (final item in rawDomains)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
    );
  }
}

class VpnProtocol {
  static const ids = <String>[
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria2',
    'tuic',
  ];

  static const labels = <String, String>{
    'vless': 'VLESS',
    'vmess': 'VMess',
    'trojan': 'Trojan',
    'shadowsocks': 'Shadowsocks',
    'hysteria2': 'Hysteria2',
    'tuic': 'TUIC',
  };

  static bool isKnown(String protocol) => ids.contains(protocol);
  static String label(String protocol) => labels[protocol] ?? protocol;
}

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
    this.backupProbeIntervalSeconds = 3,
    Map<String, bool>? enabledProtocols,
    this.startMinimized = false,
    SplitTunnelSettings? splitTunneling,
  }) : enabledProtocols = {
         for (final protocol in VpnProtocol.ids)
           protocol: enabledProtocols?[protocol] ?? true,
       },
       splitTunneling = splitTunneling ?? SplitTunnelSettings();
  ConnectionMode mode;
  bool autoQualityFailover, startMinimized;
  int qualityLatencyMs,
      failureThreshold,
      failoverCooldownSeconds,
      healthIntervalSeconds,
      backupPoolSize,
      backupProbeIntervalSeconds;
  final Map<String, bool> enabledProtocols;
  SplitTunnelSettings splitTunneling;
  bool isProtocolEnabled(String protocol) =>
      enabledProtocols[protocol] ?? VpnProtocol.isKnown(protocol);
  int get enabledProtocolCount =>
      VpnProtocol.ids.where(isProtocolEnabled).length;
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'autoQualityFailover': autoQualityFailover,
    'qualityLatencyMs': qualityLatencyMs,
    'failureThreshold': failureThreshold,
    'failoverCooldownSeconds': failoverCooldownSeconds,
    'healthIntervalSeconds': healthIntervalSeconds,
    'backupPoolSize': backupPoolSize,
    'backupProbeIntervalSeconds': backupProbeIntervalSeconds,
    'enabledProtocols': {
      for (final protocol in VpnProtocol.ids)
        protocol: isProtocolEnabled(protocol),
    },
    'startMinimized': startMinimized,
    'splitTunneling': splitTunneling.toJson(),
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final rawProtocols = j['enabledProtocols'];
    final savedProtocols = rawProtocols is Map
        ? <String, bool>{
            for (final protocol in VpnProtocol.ids)
              if (rawProtocols[protocol] is bool)
                protocol: rawProtocols[protocol] as bool,
          }
        : null;
    final rawSplitTunneling = j['splitTunneling'];
    final settings = AppSettings(
      mode:
          ConnectionMode.values.where((e) => e.name == j['mode']).firstOrNull ??
          ConnectionMode.systemProxy,
      autoQualityFailover: j['autoQualityFailover'] is bool
          ? j['autoQualityFailover'] as bool
          : true,
      qualityLatencyMs: j['qualityLatencyMs'] is num
          ? (j['qualityLatencyMs'] as num).clamp(300, 2000).toInt()
          : 800,
      failureThreshold: j['failureThreshold'] is num
          ? (j['failureThreshold'] as num).clamp(2, 6).toInt()
          : 3,
      failoverCooldownSeconds: j['failoverCooldownSeconds'] is num
          ? (j['failoverCooldownSeconds'] as num).clamp(30, 1800).toInt()
          : 300,
      healthIntervalSeconds: j['healthIntervalSeconds'] is num
          ? (j['healthIntervalSeconds'] as num).clamp(10, 60).toInt()
          : 15,
      backupPoolSize: j['backupPoolSize'] is num
          ? (j['backupPoolSize'] as num).clamp(3, 15).toInt()
          : 10,
      backupProbeIntervalSeconds: j['backupProbeIntervalSeconds'] is num
          ? (j['backupProbeIntervalSeconds'] as num).clamp(1, 25).toInt()
          : 3,
      enabledProtocols: savedProtocols,
      startMinimized: j['startMinimized'] is bool
          ? j['startMinimized'] as bool
          : false,
      splitTunneling: rawSplitTunneling is Map
          ? SplitTunnelSettings.fromJson(
              Map<String, dynamic>.from(rawSplitTunneling),
            )
          : null,
    );
    if (settings.enabledProtocolCount == 0) {
      settings.enabledProtocols['vless'] = true;
    }
    return settings;
  }
}
