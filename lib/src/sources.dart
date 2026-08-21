import 'package:http/http.dart' as http;

import 'models.dart';
import 'node_parser.dart';
import 'storage.dart';

class SourceRepository {
  SourceRepository(this.storage);
  final LocalStorage storage;
  final parser = NodeParser();

  static const defaults = <VpnSource>[
    VpnSource(
      id: 'nikita29a',
      name: 'Nikita29a FreeProxyList',
      url: 'https://raw.githubusercontent.com/nikita29a/FreeProxyList/main/mirror/1.txt',
    ),
    VpnSource(
      id: 'au1rxx',
      name: 'Au1rxx Free VPN Subscriptions',
      url: 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt',
    ),
    VpnSource(
      id: 'argh73',
      name: 'Argh73 VpnConfigCollector',
      url: 'https://raw.githubusercontent.com/Argh73/VpnConfigCollector/main/All_Configs_Sub.txt',
    ),
  ];

  Future<List<VpnNode>> fetch(VpnSource source) async {
    String? body;
    try {
      final response = await http
          .get(
            Uri.parse(source.url),
            headers: {'User-Agent': 'FreeVPNFinder/1.0'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        body = response.body;
        await storage.cacheSource(source.id, body);
      }
    } catch (_) {}
    body ??= await storage.readSourceCache(source.id);
    return body == null ? const [] : parser.parseSubscription(body, source.id);
  }

  List<VpnNode> deduplicate(
    Iterable<VpnNode> incoming,
    Iterable<VpnNode> history,
  ) {
    final previous = {for (final n in history) n.fingerprint: n};
    final result = <String, VpnNode>{};
    for (final node in incoming) {
      final old = previous[node.fingerprint];
      result[node.fingerprint] = old ?? node;
    }
    return result.values.toList()..sort((a, b) => b.score.compareTo(a.score));
  }
}
