import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

class NodeParser {
  static const schemes = {
    'vless',
    'vmess',
    'trojan',
    'ss',
    'hysteria2',
    'hy2',
    'tuic',
  };

  List<VpnNode> parseSubscription(String input, String sourceId) {
    var text = input.trim();
    if (!text.contains('://')) {
      try {
        text = utf8.decode(base64.decode(base64.normalize(text)));
      } catch (_) {}
    }
    final uris = <String>{};
    for (final line in const LineSplitter().convert(text)) {
      for (final token in line.trim().split(RegExp(r'\s+'))) {
        if (schemes.any((s) => token.toLowerCase().startsWith('$s://')))
          uris.add(token);
      }
    }
    return [
      for (final raw in uris)
        if (parseUri(raw, sourceId) case final node?) node,
    ];
  }

  VpnNode? parseUri(String raw, String sourceId) {
    try {
      if (raw.toLowerCase().startsWith('vmess://'))
        return _vmess(raw, sourceId);
      if (raw.toLowerCase().startsWith('ss://'))
        return _shadowsocks(raw, sourceId);
      final uri = Uri.parse(raw);
      final protocol = uri.scheme == 'hy2'
          ? 'hysteria2'
          : uri.scheme.toLowerCase();
      if (!schemes.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty ||
          uri.port == 0)
        return null;
      final userInfo = Uri.decodeComponent(uri.userInfo);
      final options = <String, dynamic>{
        ...uri.queryParameters,
        'credential': protocol == 'tuic' ? userInfo.split(':').first : userInfo,
        if (protocol == 'tuic' && userInfo.contains(':'))
          'password': userInfo.substring(userInfo.indexOf(':') + 1),
      };
      final name = uri.fragment.isEmpty
          ? '${protocol.toUpperCase()} ${uri.host}'
          : Uri.decodeComponent(uri.fragment);
      return _make(raw, sourceId, protocol, uri.host, uri.port, name, options);
    } catch (_) {
      return null;
    }
  }

  VpnNode? _vmess(String raw, String sourceId) {
    final map = jsonDecode(
      utf8.decode(
        base64.decode(base64.normalize(raw.substring(8).split('#').first)),
      ),
    ) as Map<String, dynamic>;
    final host = '${map['add'] ?? ''}';
    final port = int.tryParse('${map['port']}') ?? 0;
    if (host.isEmpty || port == 0) return null;
    return _make(
      raw,
      sourceId,
      'vmess',
      host,
      port,
      '${map['ps'] ?? 'VMess $host'}',
      {
        'credential': '${map['id'] ?? ''}',
        'alterId': int.tryParse('${map['aid']}') ?? 0,
        'security': '${map['scy'] ?? 'auto'}',
        'type': '${map['net'] ?? 'tcp'}',
        'path': '${map['path'] ?? ''}',
        'host': '${map['host'] ?? ''}',
        'tls': '${map['tls'] ?? ''}',
        'sni': '${map['sni'] ?? ''}',
      },
    );
  }

  VpnNode? _shadowsocks(String raw, String sourceId) {
    var body = raw.substring(5);
    final hash = body.indexOf('#');
    final name = hash >= 0
        ? Uri.decodeComponent(body.substring(hash + 1))
        : 'Shadowsocks';
    if (hash >= 0) body = body.substring(0, hash);
    body = body.split('?').first;
    if (!body.contains('@'))
      body = utf8.decode(base64.decode(base64.normalize(body)));
    final at = body.lastIndexOf('@');
    if (at < 0) return null;
    var credentials = body.substring(0, at);
    if (!credentials.contains(':'))
      credentials = utf8.decode(base64.decode(base64.normalize(credentials)));
    final endpoint = body.substring(at + 1);
    final colon = endpoint.lastIndexOf(':');
    final methodSep = credentials.indexOf(':');
    if (colon < 1 || methodSep < 1) return null;
    return _make(
      raw,
      sourceId,
      'shadowsocks',
      endpoint.substring(0, colon),
      int.parse(endpoint.substring(colon + 1)),
      name,
      {
        'method': credentials.substring(0, methodSep),
        'credential': credentials.substring(methodSep + 1),
      },
    );
  }

  VpnNode _make(
    String raw,
    String sourceId,
    String protocol,
    String host,
    int port,
    String name,
    Map<String, dynamic> options,
  ) {
    final normalized = jsonEncode({
      'protocol': protocol,
      'host': host.toLowerCase(),
      'port': port,
      'options': options,
    });
    final fingerprint = sha256.convert(utf8.encode(normalized)).toString();
    return VpnNode(
      id: fingerprint.substring(0, 16),
      fingerprint: fingerprint,
      sourceId: sourceId,
      protocol: protocol,
      host: host,
      port: port,
      name: name,
      rawConfiguration: raw,
      options: options,
    );
  }
}
