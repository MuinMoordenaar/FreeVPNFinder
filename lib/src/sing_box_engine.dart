import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'sing_box_config.dart';
import 'storage.dart';

class ProbeResult {
  const ProbeResult(this.ok, this.latency, [this.error]);
  final bool ok;
  final int latency;
  final String? error;
}

class SingBoxEngine {
  SingBoxEngine(this.storage);
  final LocalStorage storage;
  final configBuilder = SingBoxConfigBuilder();
  Process? _process;
  int proxyPort = 2080;
  ConnectionMode? activeMode;

  bool get running => _process != null;

  Future<String> get binaryPath async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      '${executableDir.path}${Platform.pathSeparator}core${Platform.pathSeparator}sing-box.exe',
      '${Directory.current.path}${Platform.pathSeparator}core${Platform.pathSeparator}sing-box.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw StateError('sing-box.exe is missing from the core folder');
  }

  Future<void> start(
    VpnNode node,
    ConnectionMode mode, {
    SplitTunnelSettings? splitTunneling,
  }) async {
    await stop();
    final config = File(
      '${storage.root.path}${Platform.pathSeparator}active-config.json',
    );
    await config.writeAsString(
      jsonEncode(
        configBuilder.build(
          node,
          mode,
          proxyPort: proxyPort,
          splitTunneling: splitTunneling,
        ),
      ),
      flush: true,
    );
    final binary = await binaryPath;
    final checked = await Process.run(binary, [
      'check',
      '-c',
      config.path,
    ], runInShell: false);
    if (checked.exitCode != 0)
      throw StateError('Invalid sing-box config: ${checked.stderr}');
    _process = await Process.start(
      binary,
      ['run', '-c', config.path],
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((e) => storage.appendLog('core: $e'));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((e) => storage.appendLog('core error: $e'));
    _process!.exitCode.then((_) {
      _process = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (_process == null) throw StateError('sing-box stopped during startup');
    activeMode = mode;
    if (mode == ConnectionMode.systemProxy) await _setSystemProxy(true);
  }

  Future<void> stop() async {
    if (activeMode == ConnectionMode.systemProxy) await _setSystemProxy(false);
    activeMode = null;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill();
      }
    }
  }

  Future<ProbeResult> checkActive({
    Duration timeout = const Duration(seconds: 8),
  }) => _httpProbe(proxyPort, timeout);

  Future<ProbeResult> probe(VpnNode node, {int port = 21800}) async {
    final binary = await binaryPath;
    final config = File(
      '${storage.root.path}${Platform.pathSeparator}probe-${node.id}.json',
    );
    await config.writeAsString(
      jsonEncode(
        configBuilder.build(
          node,
          ConnectionMode.proxyOnly,
          proxyPort: port,
          testOnly: true,
        ),
      ),
      flush: true,
    );
    Process? process;
    try {
      final checked = await Process.run(binary, ['check', '-c', config.path]);
      if (checked.exitCode != 0)
        return ProbeResult(false, 0, '${checked.stderr}');
      process = await Process.start(binary, ['run', '-c', config.path]);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return await _httpProbe(port, const Duration(seconds: 7));
    } catch (e) {
      return ProbeResult(false, 0, '$e');
    } finally {
      process?.kill();
      try {
        await config.delete();
      } catch (_) {}
    }
  }

  Future<ProbeResult> _httpProbe(int port, Duration timeout) async {
    final watch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final request = await client
          .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
          .timeout(timeout);
      request.headers.set('User-Agent', 'FreeVPNFinder/1.0');
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return ProbeResult(
        response.statusCode == 200,
        watch.elapsedMilliseconds,
        response.statusCode == 200 ? null : 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      return ProbeResult(false, watch.elapsedMilliseconds, '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _setSystemProxy(bool enabled) async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    if (enabled) {
      await Process.run('reg.exe', [
        'add',
        key,
        '/v',
        'ProxyServer',
        '/t',
        'REG_SZ',
        '/d',
        '127.0.0.1:$proxyPort',
        '/f',
      ]);
      await Process.run('reg.exe', [
        'add',
        key,
        '/v',
        'ProxyOverride',
        '/t',
        'REG_SZ',
        '/d',
        '<local>',
        '/f',
      ]);
    }
    await Process.run('reg.exe', [
      'add',
      key,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      enabled ? '1' : '0',
      '/f',
    ]);
  }
}
