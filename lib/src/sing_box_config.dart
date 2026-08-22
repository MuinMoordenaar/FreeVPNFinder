import 'models.dart';

class SingBoxConfigBuilder {
  Map<String, dynamic> build(
    VpnNode node,
    ConnectionMode mode, {
    int proxyPort = 2080,
    bool testOnly = false,
  }) {
    final inbounds = <Map<String, dynamic>>[
      {
        'type': 'mixed',
        'tag': 'local-proxy',
        'listen': '127.0.0.1',
        'listen_port': proxyPort,
      },
      if (mode == ConnectionMode.vpn && !testOnly)
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
    return {
      'log': {'level': 'info', 'timestamp': true},
      'inbounds': inbounds,
      'outbounds': [_outbound(node)],
      'route': {'final': 'selected'},
    };
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
