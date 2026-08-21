import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class LocalStorage {
  late final Directory root, cache, logs;

  Future<void> initialize() async {
    final base = await getApplicationSupportDirectory();
    root = Directory('${base.path}${Platform.pathSeparator}FreeVPNFinder');
    cache = Directory('${root.path}${Platform.pathSeparator}cache');
    logs = Directory('${root.path}${Platform.pathSeparator}logs');
    await cache.create(recursive: true);
    await logs.create(recursive: true);
  }

  Future<Map<String, dynamic>?> _read(String name) async {
    try {
      return jsonDecode(
        await File('${root.path}${Platform.pathSeparator}$name').readAsString(),
      ) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String name, Object value) async {
    final target = File('${root.path}${Platform.pathSeparator}$name');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<AppSettings> loadSettings() async =>
      AppSettings.fromJson(await _read('settings.json') ?? {});
  Future<void> saveSettings(AppSettings value) =>
      _write('settings.json', value.toJson());
  Future<List<VpnNode>> loadNodes() async {
    final data = await _read('nodes.json');
    return [
      for (final item in data?['nodes'] ?? const [])
        VpnNode.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> saveNodes(Iterable<VpnNode> value) =>
      _write('nodes.json', {'nodes': value.map((e) => e.toJson()).toList()});
  Future<List<VpnSource>?> loadSources() async {
    final data = await _read('sources.json');
    return data == null
        ? null
        : [
            for (final item in data['sources'] ?? const [])
              VpnSource.fromJson(Map<String, dynamic>.from(item)),
          ];
  }

  Future<void> saveSources(Iterable<VpnSource> value) => _write(
    'sources.json',
    {'sources': value.map((e) => e.toJson()).toList()},
  );
  Future<void> cacheSource(String id, String body) =>
      File('${cache.path}${Platform.pathSeparator}$id.txt')
          .writeAsString(body, flush: true);
  Future<String?> readSourceCache(String id) async {
    try {
      return await File('${cache.path}${Platform.pathSeparator}$id.txt')
          .readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> appendLog(String message) async {
    final stamp = DateTime.now();
    final file = File(
      '${logs.path}${Platform.pathSeparator}${stamp.toIso8601String().substring(0, 10)}.log',
    );
    await file.writeAsString(
      '[${stamp.toIso8601String()}] $message\r\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
