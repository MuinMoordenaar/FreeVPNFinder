import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class LocalStorage {
  late final Directory root, cache, logs;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _poolWriteTail = Future<void>.value();
  Future<void> _logTail = Future<void>.value();

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

  Future<void> _write(String name, Object value, {bool pool = false}) async {
    final previous = pool ? _poolWriteTail : _writeTail;
    final gate = Completer<void>();
    if (pool) {
      _poolWriteTail = gate.future;
    } else {
      _writeTail = gate.future;
    }
    try {
      try {
        await previous;
      } catch (_) {
        // A failed write must not block all subsequent saves.
      }
      final encoded = await Isolate.run(
        () => const JsonEncoder.withIndent('  ').convert(value),
      );
      final target = File('${root.path}${Platform.pathSeparator}$name');
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      gate.complete();
    }
  }

  Future<AppSettings> loadSettings() async {
    final data = await _read('settings.json');
    if (data == null && Platform.isAndroid) {
      return AppSettings(mode: ConnectionMode.vpn);
    }
    return AppSettings.fromJson(data ?? {});
  }

  Future<void> saveSettings(AppSettings value) =>
      _write('settings.json', value.toJson());
  Future<List<VpnNode>> loadNodes() async {
    final file = File('${root.path}${Platform.pathSeparator}nodes.json');
    String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      return const [];
    }
    final data = await Isolate.run(() => jsonDecode(text));
    if (data is! Map<String, dynamic>) return const [];
    return [
      for (final item in data['nodes'] ?? const [])
        VpnNode.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> saveNodes(Iterable<VpnNode> value) =>
      _write('nodes.json', {'nodes': value.map((e) => e.toJson()).toList()});

  Future<({String? active, List<String> backups, bool androidInitialPoolReady})>
  loadConnectionPool() async {
    final data = await _read('connection_pool.json');
    return (
      active: data?['activeFingerprint'] as String?,
      backups: [
        for (final value in data?['backupFingerprints'] ?? const [])
          value as String,
      ],
      androidInitialPoolReady: data?['androidInitialPoolReady'] == true,
    );
  }

  Future<void> saveConnectionPool({
    required String? activeFingerprint,
    required Iterable<String> backupFingerprints,
    bool androidInitialPoolReady = false,
  }) => _write('connection_pool.json', {
    'activeFingerprint': activeFingerprint,
    'backupFingerprints': backupFingerprints.take(15).toList(),
    'androidInitialPoolReady': androidInitialPoolReady,
    'updatedAt': DateTime.now().toIso8601String(),
  }, pool: true);
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
    final previous = _logTail;
    final gate = Completer<void>();
    _logTail = gate.future;
    final stamp = DateTime.now();
    try {
      await previous;
      final file = File(
        '${logs.path}${Platform.pathSeparator}${stamp.toIso8601String().substring(0, 10)}.log',
      );
      await file.writeAsString(
        '[${stamp.toIso8601String()}] $message\r\n',
        mode: FileMode.append,
      );
    } finally {
      gate.complete();
    }
  }
}
