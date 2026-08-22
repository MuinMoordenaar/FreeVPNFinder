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
  static const _backupReplacementMarginMs = 0;
  static const _backgroundProbeConcurrency = 4;
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
  Timer? _backgroundTimer;
  Timer? _nodesSaveTimer;
  DateTime? _lastFailover;
  int _qualityFailures = 0;
  bool _cancelRequested = false;
  bool _operationInFlight = false;
  bool _shuttingDown = false;
  bool _backupRefreshRunning = false;
  int _backgroundScanIndex = 0;
  final _backgroundGroupHistory = <String>[];

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
    _startBackgroundDiscovery();
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
    if (fresh.isNotEmpty) {
      nodes = repository.deduplicate(fresh, nodes);
      _resetBackgroundScan();
    }
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
      final reserved = <String>{};
      final candidates = <VpnNode>[];
      for (var i = 0; i < _backgroundProbeConcurrency; i++) {
        final node = _nextBackgroundCandidate(
          exclude: exclude,
          reserved: reserved,
        );
        if (node == null) break;
        candidates.add(node);
        reserved.add(node.fingerprint);
      }
      if (candidates.isEmpty || _shuttingDown) return;
      await Future<void>.delayed(
        Duration(seconds: settings.backupProbeIntervalSeconds),
      );
      if (_shuttingDown) return;

      final results = await Future.wait(
        candidates.map(_probeBackgroundCandidate),
      );
      for (final entry in results) {
        final node = entry.node;
        final result = entry.result;
        if (!result.ok) {
          node.recordFailure();
          _log('Backup candidate failed: ${node.name}');
          continue;
        }
        node.recordSuccess(result.latency);
        node.state = NodeState.standby;
        if (backups.length < settings.backupPoolSize) {
          backups.add(node);
          _log(
            'Backup ${backups.length}/${settings.backupPoolSize} ready: '
            '${node.name} (${result.latency} ms)',
          );
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
      }
      _sortAndTrimBackups();
      await _persistPool();
      notifyListeners();
      _scheduleNodesSave();
    } finally {
      _backupRefreshRunning = false;
    }
    await _persistPool();
  }

  Future<({VpnNode node, ProbeResult result})> _probeBackgroundCandidate(
    VpnNode node,
  ) async {
    _log('Background check: ${node.name} (${node.protocol})');
    try {
      final result = await engine
          .probe(node, port: 0, timeout: const Duration(seconds: 3))
          .timeout(const Duration(seconds: 5));
      return (node: node, result: result);
    } catch (e) {
      return (node: node, result: ProbeResult(false, 0, '$e'));
    }
  }

  void _scheduleNodesSave() {
    if (_nodesSaveTimer != null || _shuttingDown) return;
    _nodesSaveTimer = Timer(const Duration(seconds: 15), () {
      _nodesSaveTimer = null;
      unawaited(storage.saveNodes(nodes));
    });
  }

  VpnNode? _nextBackgroundCandidate({
    VpnNode? exclude,
    Set<String> reserved = const {},
  }) {
    if (nodes.isEmpty) return null;
    VpnNode? fallback;
    String? fallbackGroup;
    final limit = nodes.length < 256 ? nodes.length : 256;
    for (var offset = 0; offset < limit; offset++) {
      final index = (_backgroundScanIndex + offset) % nodes.length;
      final node = nodes[index];
      if (node.fingerprint == exclude?.fingerprint ||
          node.fingerprint == activeNode?.fingerprint ||
          reserved.contains(node.fingerprint) ||
          backups.any((backup) => backup.fingerprint == node.fingerprint) ||
          !_backgroundEligible(node)) {
        continue;
      }
      final group = '${node.sourceId}:${node.protocol}';
      final nodePriority = _backgroundPriority(node);
      final fallbackPriority = fallback == null
          ? 1 << 30
          : _backgroundPriority(fallback!);
      final preferred =
          fallback == null ||
          nodePriority < fallbackPriority ||
          (nodePriority == fallbackPriority &&
              (node.latency ?? 1 << 30) < (fallback!.latency ?? 1 << 30));
      if (preferred) {
        fallback = node;
        fallbackGroup = group;
      }
      if (!_backgroundGroupHistory.contains(group)) {
        _backgroundScanIndex = (index + 1) % nodes.length;
        _backgroundGroupHistory.add(group);
        if (_backgroundGroupHistory.length > 16) {
          _backgroundGroupHistory.removeAt(0);
        }
        return node;
      }
    }
    if (fallback != null) {
      final index = nodes.indexOf(fallback);
      _backgroundScanIndex = (index + 1) % nodes.length;
      if (fallbackGroup != null &&
          !_backgroundGroupHistory.contains(fallbackGroup)) {
        _backgroundGroupHistory.add(fallbackGroup);
      }
    }
    return fallback;
  }

  void _resetBackgroundScan() {
    _backgroundScanIndex = 0;
    _backgroundGroupHistory.clear();
  }

  void _startBackgroundDiscovery() {
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer.periodic(
      Duration(seconds: settings.backupProbeIntervalSeconds),
      (_) => unawaited(_fillBackups(exclude: activeNode)),
    );
    unawaited(_fillBackups(exclude: activeNode));
  }

  bool _backgroundEligible(VpnNode node) {
    if (!_eligible(node)) return false;
    final checkedAt = node.lastCheckedAt;
    return checkedAt == null ||
        DateTime.now().difference(checkedAt) >= const Duration(minutes: 5);
  }

  int _backgroundPriority(VpnNode node) {
    if (node.lastCheckedAt == null) return 0;
    if (node.consecutiveFailures > 0) return 2;
    return 1;
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
      final switched = await failover(hard: false);
      if (!switched) {
        _setPhase(AppPhase.degraded, 'Connection quality is poor');
      }
    } else {
      notifyListeners();
    }
  }

  Future<bool> failover({required bool hard}) async {
    if (hard && activeNode?.consecutiveFailures != 0) {
      _preferredNode = null;
    }
    if (backups.isEmpty) {
      _log('No prepared backup; starting a new search');
      await engine.stop();
      activeNode = null;
      await _persistPool();
      await connect();
      return connected;
    }
    if (!hard &&
        _lastFailover != null &&
        DateTime.now().difference(_lastFailover!).inSeconds <
            settings.failoverCooldownSeconds)
      return false;
    final next = lowestLatencyNode(backups);
    return _switchToBackup(next);
  }

  Future<bool> connectToBackup(VpnNode node) async {
    if (!connected ||
        !backups.any((backup) => backup.fingerprint == node.fingerprint)) {
      return false;
    }
    return _switchToBackup(node);
  }

  Future<bool> _switchToBackup(VpnNode next) async {
    backups.removeWhere((backup) => backup.fingerprint == next.fingerprint);
    await _persistPool();
    _setPhase(AppPhase.switching, 'Switching server…');
    try {
      await _activate(next);
      _lastFailover = DateTime.now();
      _qualityFailures = 0;
      unawaited(_fillBackups(exclude: next));
      return true;
    } catch (e) {
      next.recordFailure();
      _log('Backup failed: $e');
      return failover(hard: true);
    }
  }

  Future<bool> manualSwitch() => failover(hard: true);
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
    _sortAndTrimBackups();
    _resetBackgroundScan();
    await _persistPool();
    _startHealthMonitor();
    _startBackgroundDiscovery();
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
    if (backups.length <= settings.backupPoolSize) return;
    for (final node in backups.sublist(settings.backupPoolSize)) {
      node.state = NodeState.working;
    }
    backups = backups.take(settings.backupPoolSize).toList();
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
    _backgroundTimer?.cancel();
    _nodesSaveTimer?.cancel();
    try {
      await disconnect();
      await storage.saveNodes(nodes);
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
      await windowManager.destroy();
    } finally {
      _shuttingDown = false;
    }
  }
}
