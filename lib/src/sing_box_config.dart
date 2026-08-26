import 'models.dart';

class SingBoxConfigBuilder {
  Map<String, dynamic> build(
    VpnNode node,
    ConnectionMode mode, {
    int proxyPort = 2080,
    bool testOnly = false,
    SplitTunnelSettings? splitTunneling,
  }) {
    final split = splitTunneling;
    final splitEnabled = !testOnly && split?.enabled == true;
    final tunEnabled = !testOnly && mode == ConnectionMode.vpn;
    final inbounds = <Map<String, dynamic>>[
      {
        'type': 'mixed',
        'tag': 'local-proxy',
        'listen': '127.0.0.1',
        'listen_port': proxyPort,
      },
      if (tunEnabled)
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'FreeVPNFinder',
          'address': ['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
        },
    ];
    final outbounds = <Map<String, dynamic>>[
      _outbound(node),
      if (splitEnabled) {'type': 'direct', 'tag': 'direct'},
    ];
    final routeRules = <Map<String, dynamic>>[];
    if (splitEnabled && split != null) {
      // Keep these as non-final actions so the following rules can use the
      // sniffed domain and the Windows process path.
      routeRules.add({'action': 'sniff'});
      if (tunEnabled) {
        routeRules.add({
          'protocol': ['dns'],
          'action': 'hijack-dns',
        });
      }
      final target = split.mode == SplitTunnelMode.bypass
          ? 'direct'
          : 'selected';
      for (final domain in split.domains) {
        final normalized = _normalizeDomain(domain);
        if (normalized.isNotEmpty) {
          routeRules.add({
            'domain_suffix': [normalized],
            // The packaged sing-box 1.13.15 build uses this compatibility
            // field for route targets.
            'outbound': target,
          });
        }
      }
      for (final app in split.applications.where((app) => app.enabled)) {
        final path = app.path.trim();
        if (path.isNotEmpty) {
          routeRules.add({
            app.isDirectory ? 'process_path_regex' : 'process_path': [
              app.isDirectory ? _folderProcessPathRegex(path) : path,
            ],
            'outbound': target,
          });
        }
      }
    }
    return {
      'log': {'level': 'info', 'timestamp': true},
      'inbounds': inbounds,
      'outbounds': outbounds,
      if (tunEnabled && splitEnabled)
        'dns': {
          'servers': [
            {
              'type': 'https',
              'tag': 'remote-dns',
              'server': '1.1.1.1',
              'path': '/dns-query',
              'detour': 'selected',
            },
          ],
          'final': 'remote-dns',
        },
      'route': {
        if (splitEnabled && routeRules.isNotEmpty) 'rules': routeRules,
        // Prevent the VPN server and direct exceptions from being routed
        // back into the TUN interface on Windows.
        if (tunEnabled) 'auto_detect_interface': true,
        'final': splitEnabled && split!.mode == SplitTunnelMode.vpnOnly
            ? 'direct'
            : 'selected',
      },
    };
  }

  String _normalizeDomain(String value) {
    var domain = value.trim().toLowerCase();
    if (domain.startsWith('*.')) domain = domain.substring(2);
    if (domain.startsWith('https://')) domain = domain.substring(8);
    if (domain.startsWith('http://')) domain = domain.substring(7);
    domain = domain.split('/').first.split(':').first;
    return domain.endsWith('.')
        ? domain.substring(0, domain.length - 1)
        : domain;
  }

  String _folderProcessPathRegex(String value) {
    var path = value.trim().replaceAll('/', '\\');
    while (path.length > 3 && path.endsWith('\\')) {
      path = path.substring(0, path.length - 1);
    }
    final escaped = RegExp.escape(path);
    return '(?i)^$escaped\\\\(?:[^\\\\]+\\\\)*[^\\\\]+\\.exe\$';
  }

  Map<String, dynamic> _outbound(VpnNode n) {
    final q = n.options;
    final base = <String, dynamic>{
      'type': n.protocol,
      'tag': 'selected',
      'server': n.host,
      'server_port': n.port,
    };
    switch (n.protocol) {
      case 'vless':
        base['uuid'] = q['credential'];
        if ('${q['flow'] ?? ''}'.isNotEmpty) base['flow'] = q['flow'];
      case 'vmess':
        base['uuid'] = q['credential'];
        base['security'] = q['security'] ?? 'auto';
        base['alter_id'] = q['alterId'] ?? 0;
      case 'trojan':
        base['password'] = q['credential'];
      case 'shadowsocks':
        base['method'] = q['method'];
        base['password'] = q['credential'];
      case 'hysteria2':
        base['password'] = q['credential'];
        if (q['obfs'] != null)
          base['obfs'] = {
            'type': q['obfs'],
            'password': q['obfs-password'] ?? q['obfs_password'] ?? '',
          };
      case 'tuic':
        base['uuid'] = q['credential'];
        base['password'] = q['password'] ?? '';
        base['congestion_control'] = q['congestion_control'] ?? 'bbr';
    }
    final tlsEnabled =
        q['security'] == 'tls' ||
        q['security'] == 'reality' ||
        q['tls'] == 'tls' ||
        n.protocol == 'trojan' ||
        n.protocol == 'hysteria2' ||
        n.protocol == 'tuic';
    if (tlsEnabled) {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': q['sni'] ?? q['peer'] ?? n.host,
        'insecure': q['allowInsecure'] == '1' || q['insecure'] == '1',
      };
      if (q['fp'] != null)
        tls['utls'] = {'enabled': true, 'fingerprint': q['fp']};
      if (q['security'] == 'reality' || q['pbk'] != null)
        tls['reality'] = {
          'enabled': true,
          'public_key': q['pbk'] ?? '',
          'short_id': q['sid'] ?? '',
        };
      base['tls'] = tls;
    }
    final type = q['type'] ?? q['network'];
    if (type == 'ws')
      base['transport'] = {
        'type': 'ws',
        'path': q['path'] ?? '/',
        if ('${q['host'] ?? ''}'.isNotEmpty) 'headers': {'Host': q['host']},
      };
    if (type == 'grpc')
      base['transport'] = {
        'type': 'grpc',
        'service_name': q['serviceName'] ?? q['path'] ?? '',
      };
    return base;
  }
}
