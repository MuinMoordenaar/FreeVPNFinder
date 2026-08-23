import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_vpn_finder/src/models.dart';
import 'package:free_vpn_finder/src/node_parser.dart';
import 'package:free_vpn_finder/src/reconnect_policy.dart';
import 'package:free_vpn_finder/src/sing_box_config.dart';

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
}
