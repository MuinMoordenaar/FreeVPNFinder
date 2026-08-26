import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_vpn_finder/src/models.dart';
import 'package:free_vpn_finder/src/node_parser.dart';
import 'package:free_vpn_finder/src/reconnect_policy.dart';
import 'package:free_vpn_finder/src/sing_box_config.dart';
import 'package:free_vpn_finder/src/sing_box_engine.dart';

void main() {
  final parser = NodeParser();

  test('desktop defaults to System Proxy mode', () {
    expect(AppSettings().mode, ConnectionMode.systemProxy);
  });

  test(
    'new settings enable every protocol and check backups every 3 seconds',
    () {
      final settings = AppSettings();
      expect(settings.backupProbeIntervalSeconds, 3);
      expect(settings.enabledProtocolCount, VpnProtocol.ids.length);
      expect(settings.isProtocolEnabled('shadowsocks'), isTrue);
    },
  );

  test('protocol settings migrate safely and never disable everything', () {
    final old = AppSettings.fromJson({});
    expect(old.enabledProtocolCount, VpnProtocol.ids.length);
    final migrated = AppSettings.fromJson({
      'enabledProtocols': {
        for (final protocol in VpnProtocol.ids) protocol: false,
      },
      'backupPoolSize': 'invalid',
      'backupProbeIntervalSeconds': 'invalid',
    });
    expect(migrated.enabledProtocolCount, 1);
    expect(migrated.isProtocolEnabled('vless'), isTrue);
    expect(migrated.backupPoolSize, 10);
    expect(migrated.backupProbeIntervalSeconds, 3);
  });

  test('backup pool settings stay within their supported ranges', () {
    final settings = AppSettings.fromJson({
      'backupPoolSize': 99,
      'backupProbeIntervalSeconds': 0,
    });
    expect(settings.backupPoolSize, 15);
    expect(settings.backupProbeIntervalSeconds, 1);
  });

  test('split tunneling settings migrate and round-trip safely', () {
    final settings = AppSettings.fromJson({
      'splitTunneling': {
        'enabled': true,
        'mode': 'vpnOnly',
        'applications': [
          {'name': 'Browser', 'path': r'C:\Apps\browser.exe'},
        ],
        'domains': ['example.com'],
      },
    });
    expect(settings.splitTunneling.enabled, isTrue);
    expect(settings.splitTunneling.mode, SplitTunnelMode.vpnOnly);
    expect(
      settings.splitTunneling.applications.single.path,
      r'C:\Apps\browser.exe',
    );
    expect(settings.splitTunneling.domains, ['example.com']);

    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.splitTunneling.mode, SplitTunnelMode.vpnOnly);
    expect(restored.splitTunneling.applications.single.name, 'Browser');
  });

  test('VPN split tunneling creates working direct and VPN routes', () {
    final node = parser.parseUri(
      'vless://11111111-1111-1111-1111-111111111111@example.com:443#Test',
      'test',
    )!;
    final split = SplitTunnelSettings(
      enabled: true,
      mode: SplitTunnelMode.vpnOnly,
      applications: [
        SplitTunnelApp(name: 'Browser', path: r'C:\Apps\browser.exe'),
      ],
      domains: ['https://example.com/'],
    );
    for (final mode in ConnectionMode.values) {
      final config = SingBoxConfigBuilder().build(
        node,
        mode,
        splitTunneling: split,
      );
      final route = config['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      final outbounds = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>();

      expect(
        (config['inbounds'] as List).any((inbound) {
          return (inbound as Map)['type'] == 'tun';
        }),
        mode == ConnectionMode.vpn,
      );
      expect(outbounds.map((outbound) => outbound['tag']), contains('direct'));
      expect(
        route['auto_detect_interface'],
        mode == ConnectionMode.vpn ? isTrue : isNull,
      );
      expect(rules.any((rule) => rule['action'] == 'sniff'), isTrue);
      expect(
        rules.any((rule) => rule['action'] == 'hijack-dns'),
        mode == ConnectionMode.vpn,
      );
      expect(
        rules.any(
          (rule) =>
              rule['domain_suffix'] is List && rule['outbound'] == 'selected',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              rule['process_path'] is List && rule['outbound'] == 'selected',
        ),
        isTrue,
      );
      expect(route['final'], 'direct');
    }
  });

  test('system proxy split bypass exports exact and subdomain exceptions', () {
    final split = SplitTunnelSettings(
      enabled: true,
      mode: SplitTunnelMode.bypass,
      domains: ['https://2IP.io/'],
    );
    expect(buildSystemProxyOverride(split), '<local>;2ip.io;*.2ip.io');
    expect(
      buildSystemProxyOverride(
        SplitTunnelSettings(enabled: true, mode: SplitTunnelMode.vpnOnly),
      ),
      '<local>',
    );
  });

  test('parses and deduplicates vless share links', () {
    const uri =
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=reality&sni=example.com&pbk=abc&sid=01&type=tcp#Test';
    final encoded = base64.encode(utf8.encode('$uri\n$uri'));
    final nodes = parser.parseSubscription(encoded, 'test');
    expect(nodes, hasLength(1));
    expect(nodes.single.protocol, 'vless');
    expect(nodes.single.name, 'Test');
  });

  test('parses vmess and builds proxy config', () {
    final vmess = base64.encode(
      utf8.encode(
        jsonEncode({
          'add': 'server.test',
          'port': '443',
          'id': 'uuid',
          'ps': 'VMess Test',
          'net': 'ws',
          'path': '/ws',
          'tls': 'tls',
        }),
      ),
    );
    final node = parser.parseUri('vmess://$vmess', 'test')!;
    final config = SingBoxConfigBuilder().build(node, ConnectionMode.proxyOnly);
    expect((config['inbounds'] as List).single['type'], 'mixed');
    expect((config['outbounds'] as List).single['transport']['type'], 'ws');
  });

  test('fingerprint ignores display name', () {
    final a = parser.parseUri(
      'trojan://password@example.com:443?sni=example.com#A',
      'one',
    )!;
    final b = parser.parseUri(
      'trojan://password@example.com:443?sni=example.com#B',
      'two',
    )!;
    expect(a.fingerprint, b.fingerprint);
  });

  test('parses Shadowsocks SIP002 links and builds a proxy config', () {
    final node = parser.parseUri(
      "ss://${base64.encode(utf8.encode('aes-256-gcm:password'))}@example.com:8388#SS",
      'test',
    );
    expect(node, isNotNull);
    expect(node!.protocol, 'shadowsocks');
    expect(node.options['method'], 'aes-256-gcm');
    expect(node.options['credential'], 'password');
    final config = SingBoxConfigBuilder().build(node, ConnectionMode.proxyOnly);
    final outbound = (config['outbounds'] as List).single as Map;
    expect(outbound['type'], 'shadowsocks');
    expect(outbound['method'], 'aes-256-gcm');
    expect(outbound['password'], 'password');
  });

  test('parses legacy base64 Shadowsocks links', () {
    final payload = base64.encode(
      utf8.encode('aes-128-gcm:password@example.com:8388'),
    );
    final node = parser.parseUri('ss://$payload#Legacy SS', 'test');
    expect(node, isNotNull);
    expect(node!.protocol, 'shadowsocks');
    expect(node.host, 'example.com');
    expect(node.port, 8388);
  });

  test('recent reconnect tries the previous active node before backups', () {
    final active = parser.parseUri(
      'trojan://active@example.com:443#Active',
      'saved',
    )!;
    final backup = parser.parseUri(
      'trojan://backup@example.net:443#Backup',
      'saved',
    )!;
    final candidates = recentConnectionCandidates(active, [backup, active]);
    expect(candidates, [active, backup]);
  });

  test('quality failover selects the lowest-ping backup', () {
    final slow = parser.parseUri('trojan://slow@example.com:443#Slow', 'test')!
      ..latency = 220;
    final fast = parser.parseUri('trojan://fast@example.com:443#Fast', 'test')!
      ..latency = 45;
    final unknown = parser.parseUri(
      'trojan://unknown@example.com:443#Unknown',
      'test',
    )!..latency = null;
    expect(lowestLatencyNode([slow, unknown, fast]), fast);
  });

  test('sing-box accepts generated configs for every MVP protocol', () async {
    final binary = File('core${Platform.pathSeparator}sing-box.exe')
        .absolute
        .path;
    final samples = [
      'vless://11111111-1111-1111-1111-111111111111@example.com:443#VLESS',
      'trojan://secret@example.com:443?sni=example.com#Trojan',
      'hysteria2://secret@example.com:443?sni=example.com#HY2',
      'tuic://11111111-1111-1111-1111-111111111111:secret@example.com:443?sni=example.com#TUIC',
      "ss://${base64.encode(utf8.encode('aes-256-gcm:secret'))}@example.com:8388#SS",
    ];
    for (final uri in samples) {
      final node = parser.parseUri(uri, 'test');
      expect(node, isNotNull, reason: uri);
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fvf-${node!.id}.json',
      );
      await file.writeAsString(
        jsonEncode(
          SingBoxConfigBuilder().build(node, ConnectionMode.proxyOnly),
        ),
      );
      final result = await Process.run(binary, ['check', '-c', file.path]);
      await file.delete();
      expect(result.exitCode, 0, reason: '$uri\n${result.stderr}');
    }
  });

  test('sing-box accepts the generated Windows split tunnel config', () async {
    final binary = File('core${Platform.pathSeparator}sing-box.exe')
        .absolute
        .path;
    final node = parser.parseUri(
      'vless://11111111-1111-1111-1111-111111111111@example.com:443#Split',
      'test',
    )!;
    for (final mode in ConnectionMode.values) {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'fvf-split-${mode.name}-${DateTime.now().microsecondsSinceEpoch}.json',
      );
      await file.writeAsString(
        jsonEncode(
          SingBoxConfigBuilder().build(
            node,
            mode,
            splitTunneling: SplitTunnelSettings(
              enabled: true,
              mode: SplitTunnelMode.bypass,
              applications: [
                SplitTunnelApp(
                  name: 'Notepad',
                  path: r'C:\Windows\System32\notepad.exe',
                ),
              ],
              domains: ['example.com'],
            ),
          ),
        ),
      );
      final result = await Process.run(binary, ['check', '-c', file.path]);
      await file.delete();
      expect(
        result.exitCode,
        0,
        reason: '${mode.name}\n${result.stdout}\n${result.stderr}',
      );
    }
  });
}
