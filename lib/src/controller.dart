import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'node_parser.dart';
import 'reconnect_policy.dart';
import 'sing_box_engine.dart';
import 'sources.dart';
import 'storage.dart';

class AppController extends ChangeNotifier with TrayListener, WindowListener {
  static const _backupPoolSize = 10;
  // Exactly one short probe at a time: this keeps background discovery quiet
  // while still allowing the pool to converge on lower-latency nodes.
  static const _backupProbeDelay = Duration(seconds: 5);
  static const _backupReplacementMarginMs = 0;
  final storage = LocalStorage();
  late final SourceRepository repository;
  late final SingBoxEngine engine;
  AppSettings settings = AppSettings();
  List<VpnSource> sources = [];
  List<VpnNode> nodes = [], backups = [];
  VpnNode? activeNode;
  VpnNode? _preferredNode;
  AppPhase phase = AppPhase.disconnected;
  String status = 'Ready';
  String? error;
  final logs = <String>[];
  int tested = 0;
  Timer? _healthTimer;
  DateTime? _lastFailover;
  int _qualityFailures = 0;
  bool _cancelRequested = false;
  bool _operationInFlight = false;
  bool _shuttingDown = false;
  bool _backupRefreshRunning = false;

  bool get connected =>
      phase == AppPhase.connected || phase == AppPhase.degraded;

  Future<void> initialize() async {
    await storage.initialize();
    repository = SourceRepository(storage);
    engine = SingBoxEngine(storage);
    settings = await storage.loadSettings();
    nodes = (await storage.loadNodes()).where(_supported).toList();
    final savedPool = await storage.loadConnectionPool();
    final nodesByFingerprint = {
      for (final node in nodes) node.fingerprint: node,
    };
    _preferredNode = nodesByFingerprint[savedPool.active];
    backups = [
      for (final fingerprint in savedPool.backups)
        if (nodesByFingerprint[fingerprint] case final node?)
          node..state = NodeState.standby,
    ];
    _sortAndTrimBackups();
    sources = await storage.loadSources() ?? SourceRepository.defaults.toList();
    trayManager.addListener(this);
    windowManager.addListener(this);
    await _setupTray();
    _log(
      'Application initialized with ${nodes.length} cached nodes and ${backups.length} saved backups',
    );
  }

  Future<void> _setupTray() async {
    try {
      final packagedIcon = File(
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}app_icon.ico',
      );
      await trayManager.setIcon(
        await packagedIcon.exists()
            ? packagedIcon.path
            : 'windows/runner/resources/app_icon.ico',
      );
      await trayManager.setToolTip('Free VPN Finder');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open Free VPN Finder'),
            MenuItem(
              key: 'toggle',
              label: connected ? 'Disconnect' : 'Connect',
            ),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Exit'),
          ],
        ),
      );
    } catch (e) {
      _log('Tray unavailable: $e');
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'show') onTrayIconMouseDown();
    if (item.key == 'toggle') await toggleConnection();
    if (item.key == 'exit') await shutdown();
  }

  @override
  void onWindowClose() async {
    await shutdown();
  }

  void _setPhase(AppPhase value, String message) {
    phase = value;
    status = message;
    error = null;
    notifyListeners();
  }

  void _log(String message) {
    logs.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (logs.length > 300) logs.removeLast();
    storage.appendLog(message);
    notifyListeners();
  }

  Future<void> toggleConnection() async {
    if (_operationInFlight || _shuttingDown) return;
    _operationInFlight = true;
    try {
      if (phase == AppPhase.disconnected) {
        await connect();
      } else {
        await disconnect();
      }
    } finally {
      _operationInFlight = false;
    }
  }

  Future<void> connect() async {
    _cancelRequested = false;
    tested = 0;
    try {
      _setPhase(AppPhase.searching, 'Checking your recent servers…');
      final attempted = <String>{};
      final recent = recentConnectionCandidates(_preferredNode, backups);
      final cachedWinner = await _findFirstWorking(recent, attempted);
      if (cachedWinner != null) {
        await _activate(cachedWinner);
        unawaited(_fillBackups(exclude: cachedWinner));
        return;
      }

      _preferredNode = null;
      backups.removeWhere((node) => attempted.contains(node.fingerprint));
      await _persistPool();
      await refreshSources();
      if (_cancelRequested) return;
      _setPhase(AppPhase.searching, 'Searching for a working server…');
      final winner = await _findFirstWorking(
        nodes.where(_eligible).take(80),
        attempted,
      );
      if (winner != null) {
        await _activate(winner);
        unawaited(_fillBackups(exclude: winner));
        return;
      }
      throw StateError('No working servers found');
    } catch (e) {
      _fail('$e');
    } finally {
      await storage.saveNodes(nodes);
      await _setupTray();
    }
  }

  Future<VpnNode?> _findFirstWorking(
    Iterable<VpnNode> candidates,
    Set<String> attempted,
  ) async {
    for (final node in candidates) {
      if (_cancelRequested) return null;
      if (!_eligible(node)) continue;
      if (!attempted.add(node.fingerprint)) continue;
      tested++;
      node.state = NodeState.checking;
      notifyListeners();
      final result = await engine.probe(node, port: 21800 + tested % 100);
      if (result.ok) {
        node.recordSuccess(result.latency);
        _log('${node.name} passed in ${result.latency} ms');
        return node;
      }
      node.recordFailure();
      _log('${node.name} failed: ${result.error ?? 'unreachable'}');
    }
    return null;
  }

  bool _supported(VpnNode n) => n.protocol != 'shadowsocks';

  bool _eligible(VpnNode n) =>
      _supported(n) &&
      (n.state != NodeState.cooldown ||
          n.lastFailureAt == null ||
          DateTime.now().difference(n.lastFailureAt!).inHours >= 1);

  Future<void> refreshSources() async {
    _setPhase(AppPhase.updatingSources, 'Updating server sources…');
    final fresh = <VpnNode>[];
    for (final source in sources.where((s) => s.enabled)) {
      if (_cancelRequested) return;
      final result = await repository.fetch(source);
      fresh.addAll(result);
      _log('${source.name}: ${result.length} configurations');
    }
    if (fresh.isNotEmpty) nodes = repository.deduplicate(fresh, nodes);
    await storage.saveNodes(nodes);
    _log('${nodes.length} unique nodes available');
  }

  Future<void> _activate(VpnNode node) async {
    final previous = activeNode;
    _setPhase(AppPhase.connecting, 'Connecting to ${node.name}…');
    await engine.start(node, settings.mode);
    _setPhase(AppPhase.verifying, 'Verifying connection…');
    final result = await engine.checkActive();
    if (!result.ok) {
      await engine.stop();
      node.recordFailure();
      throw StateError('Connection verification failed');
    }
    if (previous != null &&
        previous.fingerprint != node.fingerprint &&
        previous.consecutiveFailures == 0 &&
        !backups.any((backup) => backup.fingerprint == previous.fingerprint)) {
      previous.state = NodeState.standby;
      backups.add(previous);
    }
    backups.removeWhere((backup) => backup.fingerprint == node.fingerprint);
    _sortAndTrimBackups();
    activeNode = node..state = NodeState.active;
    _preferredNode = node;
    node.recordSuccess(result.latency);
    node.state = NodeState.active;
    _setPhase(AppPhase.connected, 'Connected');
    _log(
      'Connected to ${node.name} (${result.latency} ms) using ${settings.mode.label}',
    );
    _startHealthMonitor();
    await _persistPool();
  }

  Future<void> _fillBackups({VpnNode? exclude}) async {
    if (_backupRefreshRunning) return;
    _backupRefreshRunning = true;
    backups = backups
        .where((n) => n.fingerprint != exclude?.fingerprint)
        .toList();
    try {
      for (final node in nodes.where(
        (n) =>
            _eligible(n) &&
            n.fingerprint != activeNode?.fingerprint &&
            !backups.any((b) => b.fingerprint == n.fingerprint),
      )) {
        if (_cancelRequested || !connected) break;
        await Future<void>.delayed(_backupProbeDelay);
        if (_cancelRequested || !connected) break;

        final result = await engine.probe(node, port: 21950);
        if (!result.ok) {
          node.recordFailure();
          continue;
        }

        node.recordSuccess(result.latency);
        node.state = NodeState.standby;
        if (backups.length < _backupPoolSize) {
          backups.add(node);
          _log('Backup ${backups.length}/$_backupPoolSize ready: ${node.name}');
        } else {
          final slowest = backups.reduce(
            (a, b) => latencyOrder(a, b) >= 0 ? a : b,
          );
          if (result.latency + _backupReplacementMarginMs <
              (slowest.latency ?? 1 << 30)) {
            slowest.state = NodeState.working;
            backups
              ..remove(slowest)
              ..add(node);
            _log(
              'Backup replaced: ${slowest.name} → ${node.name} '
              '(${result.latency} ms)',
            );
          }
        }
        _sortAndTrimBackups();
        await _persistPool();
        notifyListeners();
      }
      await storage.saveNodes(nodes);
    } finally {
      _backupRefreshRunning = false;
    }
    await storage.saveNodes(nodes);
    await _persistPool();
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      Duration(seconds: settings.healthIntervalSeconds),
      (_) => _healthCheck(),
    );
  }

  Future<void> _healthCheck() async {
    if (!connected || activeNode == null) return;
    final result = await engine.checkActive();
    if (!result.ok) {
      activeNode!.recordFailure();
      _qualityFailures++;
      _log(
        'Health check failed ($_qualityFailures/${settings.failureThreshold})',
      );
      if (_qualityFailures >= settings.failureThreshold)
        await failover(hard: true);
      return;
    }
    activeNode!.recordSuccess(result.latency);
    activeNode!.state = NodeState.active;
    if (result.latency > settings.qualityLatencyMs)
      _qualityFailures++;
    else
      _qualityFailures = 0;
    if (settings.autoQualityFailover &&
        _qualityFailures >= settings.failureThreshold) {
      _setPhase(AppPhase.degraded, 'Connection quality is poor');
      await failover(hard: false);
    } else {
      notifyListeners();
    }
  }

  Future<void> failover({required bool hard}) async {
    if (hard && activeNode?.consecutiveFailures != 0) {
      _preferredNode = null;
    }
    if (backups.isEmpty) {
      _log('No prepared backup; starting a new search');
      await engine.stop();
      activeNode = null;
      await _persistPool();
      await connect();
      return;
    }
    if (!hard &&
        _lastFailover != null &&
        DateTime.now().difference(_lastFailover!).inSeconds <
            settings.failoverCooldownSeconds)
      return;
    final next = lowestLatencyNode(backups);
    await _switchToBackup(next);
  }

  Future<void> connectToBackup(VpnNode node) async {
    if (!connected ||
        !backups.any((backup) => backup.fingerprint == node.fingerprint)) {
      return;
    }
    await _switchToBackup(node);
  }

  Future<void> _switchToBackup(VpnNode next) async {
    backups.removeWhere((backup) => backup.fingerprint == next.fingerprint);
    await _persistPool();
    _setPhase(AppPhase.switching, 'Switching server…');
    try {
      await _activate(next);
      _lastFailover = DateTime.now();
      _qualityFailures = 0;
      unawaited(_fillBackups(exclude: next));
    } catch (e) {
      next.recordFailure();
      _log('Backup failed: $e');
      await failover(hard: true);
    }
  }

  Future<void> manualSwitch() => failover(hard: true);
  Future<void> disconnect() async {
    _cancelRequested = true;
    _healthTimer?.cancel();
    _setPhase(AppPhase.disconnecting, 'Disconnecting…');
    if (activeNode != null) {
      _preferredNode = activeNode;
      activeNode!.state = NodeState.working;
    }
    await _persistPool();
    await engine.stop();
    activeNode = null;
    _setPhase(AppPhase.disconnected, 'Ready');
    await _setupTray();
  }

  Future<void> changeMode(ConnectionMode mode) async {
    final reconnect = connected;
    settings.mode = mode;
    await storage.saveSettings(settings);
    if (reconnect) {
      final node = activeNode!;
      await engine.stop();
      await _activate(node);
    }
    notifyListeners();
  }

  Future<void> addCustomUri(String raw) async {
    final node = NodeParser().parseUri(raw.trim(), 'custom');
    if (node == null) throw FormatException('Unsupported or invalid URI');
    nodes = repository.deduplicate([node, ...nodes], nodes);
    await storage.saveNodes(nodes);
    _log('Custom ${node.protocol} profile added');
  }

  Future<void> addSubscription(String url, {String? name}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme)
      throw FormatException('Invalid subscription URL');
    final source = VpnSource(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      name: name?.trim().isNotEmpty == true ? name!.trim() : uri.host,
      url: uri.toString(),
      custom: true,
    );
    sources.add(source);
    await storage.saveSources(sources);
    _log('Subscription ${source.name} added');
  }

  Future<void> setSourceEnabled(int index, bool enabled) async {
    sources[index] = sources[index].copyWith(enabled: enabled);
    await storage.saveSources(sources);
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await storage.saveSettings(settings);
    _startHealthMonitor();
    notifyListeners();
  }

  Future<void> _persistPool() => storage.saveConnectionPool(
    activeFingerprint: _preferredNode?.fingerprint,
    backupFingerprints: () {
      final sorted =
          backups
              .where((node) => node.fingerprint != activeNode?.fingerprint)
              .toList()
            ..sort(latencyOrder);
      return sorted.map((node) => node.fingerprint);
    }(),
  );

  void _sortAndTrimBackups() {
    backups.sort(latencyOrder);
    if (backups.length <= _backupPoolSize) return;
    for (final node in backups.sublist(_backupPoolSize)) {
      node.state = NodeState.working;
    }
    backups = backups.take(_backupPoolSize).toList();
  }

  void _fail(String message) {
    error = message.replaceFirst('Bad state: ', '');
    phase = AppPhase.error;
    status = error!;
    _log('Error: $error');
  }

  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await disconnect();
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
      await windowManager.destroy();
    } finally {
      _shuttingDown = false;
    }
  }
}
