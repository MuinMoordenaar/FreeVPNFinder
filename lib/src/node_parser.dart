import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

class NodeParser {
  static const schemes = {
    'ss',
    'vless',
    'vmess',
    'trojan',
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

  VpnNode? _shadowsocks(String raw, String sourceId) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;

    var host = uri.host;
    var port = uri.port;
    var userInfo = uri.userInfo;
    var decoded = _decodeBase64(userInfo) ?? Uri.decodeComponent(userInfo);

    // Also accept the legacy form where the complete method/password@host:port
    // payload is base64 encoded after ss://.
    if (host.isEmpty || port == 0 || userInfo.isEmpty) {
      final payload = raw.substring(5).split('#').first.split('?').first;
      decoded = _decodeBase64(payload) ?? Uri.decodeComponent(payload);
      final separator = decoded.lastIndexOf('@');
      if (separator <= 0 || separator == decoded.length - 1) return null;
      userInfo = decoded.substring(0, separator);
      final endpoint = Uri.tryParse('ss://${decoded.substring(separator + 1)}');
      if (endpoint == null || endpoint.host.isEmpty || endpoint.port == 0)
        return null;
      host = endpoint.host;
      port = endpoint.port;
    }

    final separator = decoded.indexOf(':');
    if (separator <= 0 || separator == decoded.length - 1) return null;
    final method = decoded.substring(0, separator).trim();
    final password = decoded.substring(separator + 1);
    if (method.isEmpty || password.isEmpty || host.isEmpty || port == 0)
      return null;
    final name = uri.fragment.isEmpty
        ? 'SHADOWSOCKS $host'
        : Uri.decodeComponent(uri.fragment);
    return _make(raw, sourceId, 'shadowsocks', host, port, name, {
      ...uri.queryParameters,
      'method': method,
      'credential': password,
    });
  }

  String? _decodeBase64(String value) {
    if (value.isEmpty) return null;
    try {
      final decoded = utf8.decode(
        base64.decode(base64.normalize(Uri.decodeComponent(value))),
      );
      if (decoded.contains(':') &&
          !decoded.contains(RegExp(r'[\u0000-\u001F\u007F]'))) {
        return decoded;
      }
    } catch (_) {}
    return null;
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
