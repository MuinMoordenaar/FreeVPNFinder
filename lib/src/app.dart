import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'models.dart';

const bg = Color(0xFF090C12),
    panel = Color(0xFF151517),
    blue = Color(0xFFF2F2F2),
    cyan = Color(0xFFB8B8BC);
const appVersion = '1.1.9';

class FreeVpnFinderApp extends StatelessWidget {
  const FreeVpnFinderApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Free VPN Finder',
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: blue,
        secondary: cyan,
        surface: panel,
      ),
      textTheme: ThemeData.dark().textTheme.apply(
        fontFamily: 'Segoe UI',
        bodyColor: const Color(0xFFE9E9EC),
        displayColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2B2B30)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0D0D0F),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF101012),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    home: Dashboard(controller: controller),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.controller});
  final AppController controller;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  int page = 0;
  static const nav = [
    (3, Icons.tune_rounded, 'Settings'),
    (1, Icons.radar_rounded, 'Sources'),
    (2, Icons.add_link_rounded, 'Profiles'),
    (4, Icons.terminal_rounded, 'Logs'),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, __) {
      final c = widget.controller;
      return Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(color: bg),
          child: Column(
            children: [
              const _WindowBar(),
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 210,
                      margin: const EdgeInsets.fromLTRB(12, 0, 10, 12),
                      padding: const EdgeInsets.symmetric(
                        vertical: 18,
                        horizontal: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111113),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2B2B30)),
                      ),
                      child: Column(
                        children: [
                          _NavItem(
                            icon: Icons.shield_rounded,
                            label: 'Connect',
                            selected: page == 0,
                            onTap: () => setState(() => page = 0),
                          ),
                          const SizedBox(height: 16),
                          for (var i = 0; i < nav.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _NavItem(
                                icon: nav[i].$2,
                                label: nav[i].$3,
                                selected: page == nav[i].$1,
                                onTap: () => setState(() => page = nav[i].$1),
                              ),
                            ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B1B1E),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: c.connected
                                        ? const Color(0xFFF4F4F4)
                                        : const Color(0xFF6E6E73),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    c.connected
                                        ? 'Route active'
                                        : 'Not connected',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 12, 12),
                        child: IndexedStack(
                          index: page,
                          children: [
                            _Home(c),
                            _Sources(c),
                            _Profiles(c),
                            _Settings(c),
                            _Logs(c),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Home extends StatelessWidget {
  const _Home(this.c);
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final busy = !{
      AppPhase.disconnected,
      AppPhase.connected,
      AppPhase.degraded,
      AppPhase.error,
    }.contains(c.phase);
    final active = c.connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              const Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    'Free VPN Finder',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'v$appVersion',
                    style: TextStyle(fontSize: 14, color: Colors.white38),
                  ),
                ],
              ),
              const Spacer(),
              DropdownButtonHideUnderline(
                child: DropdownButton<ConnectionMode>(
                  value: c.settings.mode,
                  borderRadius: BorderRadius.circular(10),
                  dropdownColor: const Color(0xFF1B1B1E),
                  items: [
                    for (final m in ConnectionMode.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: busy
                      ? null
                      : (m) {
                          if (m != null) c.changeMode(m);
                        },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ConnectButton(
                          active: active,
                          busy: busy,
                          error: c.phase == AppPhase.error,
                          onTap: c.toggleConnection,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          c.status.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            letterSpacing: 1.8,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? Colors.white
                                : busy
                                ? cyan
                                : c.phase == AppPhase.error
                                ? const Color(0xFFB8B8BC)
                                : Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          c.activeNode?.name ??
                              (busy ? 'Testing node ${c.tested}' : ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          c.activeNode == null
                              ? '${c.nodes.length} cached servers'
                              : '${c.activeNode!.protocol.toUpperCase()}  •  ${c.activeNode!.host}:${c.activeNode!.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    SizedBox(
                      height: 154,
                      child: _InfoCard(
                        title: 'CONNECTION',
                        icon: Icons.speed_rounded,
                        children: [
                          _Stat(
                            label: 'Latency',
                            value: c.activeNode?.latency == null
                                ? '—'
                                : '${c.activeNode!.latency} ms',
                          ),
                          _Stat(
                            label: 'Protocol',
                            value: c.activeNode?.protocol.toUpperCase() ?? '—',
                          ),
                          _Stat(label: 'Mode', value: c.settings.mode.label),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 216,
                      child: _InfoCard(
                        title: 'FAILOVER',
                        icon: Icons.swap_horiz_rounded,
                        children: [
                          _Stat(
                            label: 'Backup nodes',
                            value: '${c.backups.length} / 5',
                          ),
                          _Stat(
                            label: 'Auto quality switch',
                            value: c.settings.autoQualityFailover
                                ? 'On'
                                : 'Off',
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: active && c.backups.isNotEmpty
                                  ? c.manualSwitch
                                  : null,
                              icon: const Icon(Icons.shuffle_rounded, size: 18),
                              label: const Text('Switch server'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: c.installingUpdate ? null : c.updateAction,
                        icon: c.checkingUpdate || c.installingUpdate
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.system_update_alt_rounded),
                        label: Text(
                          c.availableUpdate == null
                              ? 'Update'
                              : 'Install ${c.availableUpdate!.version}',
                        ),
                      ),
                    ),
                    if (c.updateMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          c.updateMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Sources extends StatelessWidget {
  const _Sources(this.c);
  final AppController c;
  @override
  Widget build(BuildContext context) => _Page(
    title: 'Sources',
    subtitle: 'Public lists and your own subscriptions',
    action: FilledButton.icon(
      onPressed: c.phase == AppPhase.disconnected || c.phase == AppPhase.error
          ? c.refreshSources
          : null,
      icon: const Icon(Icons.refresh),
      label: const Text('Refresh'),
    ),
    child: ListView.separated(
      itemCount: c.sources.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final s = c.sources[i];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: CircleAvatar(
              backgroundColor: blue.withValues(alpha: .15),
              child: Icon(s.custom ? Icons.link : Icons.public, color: cyan),
            ),
            title: Text(
              s.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Switch(
              value: s.enabled,
              onChanged: (v) => c.setSourceEnabled(i, v),
            ),
          ),
        );
      },
    ),
  );
}

class _Profiles extends StatefulWidget {
  const _Profiles(this.c);
  final AppController c;
  @override
  State<_Profiles> createState() => _ProfilesState();
}

class _ProfilesState extends State<_Profiles> {
  final uri = TextEditingController(), sub = TextEditingController();
  String? message;
  @override
  Widget build(BuildContext context) => _Page(
    title: 'Custom profiles',
    subtitle: 'Add a share URI or subscription URL',
    child: ListView(
      children: [
        _FormCard(
          title: 'Single configuration',
          hint: 'vless://  vmess://  trojan://  ss://  hysteria2://  tuic://',
          controller: uri,
          button: 'Add profile',
          onTap: () async {
            try {
              await widget.c.addCustomUri(uri.text);
              uri.clear();
              setState(() => message = 'Profile added');
            } catch (e) {
              setState(() => message = '$e');
            }
          },
        ),
        const SizedBox(height: 14),
        _FormCard(
          title: 'Subscription URL',
          hint: 'https://example.com/subscription',
          controller: sub,
          button: 'Add subscription',
          onTap: () async {
            try {
              await widget.c.addSubscription(sub.text);
              sub.clear();
              setState(() => message = 'Subscription added');
            } catch (e) {
              setState(() => message = '$e');
            }
          },
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(message!, style: const TextStyle(color: cyan)),
          ),
      ],
    ),
  );
}

class _Settings extends StatelessWidget {
  const _Settings(this.c);
  final AppController c;
  @override
  Widget build(BuildContext context) => _Page(
    title: 'Settings',
    subtitle: 'Health checks and automatic failover',
    child: ListView(
      children: [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Quality failover'),
                subtitle: const Text(
                  'Switch after repeated slow health checks',
                ),
                value: c.settings.autoQualityFailover,
                onChanged: (v) {
                  c.settings.autoQualityFailover = v;
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              _SliderSetting(
                title: 'Poor latency threshold',
                value: c.settings.qualityLatencyMs.toDouble(),
                min: 300,
                max: 2000,
                suffix: 'ms',
                onChanged: (v) {
                  c.settings.qualityLatencyMs = v.round();
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              _SliderSetting(
                title: 'Consecutive failures',
                value: c.settings.failureThreshold.toDouble(),
                min: 2,
                max: 6,
                suffix: '',
                onChanged: (v) {
                  c.settings.failureThreshold = v.round();
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              _SliderSetting(
                title: 'Health-check interval',
                value: c.settings.healthIntervalSeconds.toDouble(),
                min: 10,
                max: 60,
                suffix: 's',
                onChanged: (v) {
                  c.settings.healthIntervalSeconds = v.round();
                  c.saveSettings();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline, color: cyan),
            title: Text('VPN mode requires administrator rights'),
            subtitle: Text(
              'System Proxy affects apps that follow Windows proxy settings. Proxy Only listens on 127.0.0.1:2080.',
            ),
          ),
        ),
      ],
    ),
  );
}

class _Logs extends StatelessWidget {
  const _Logs(this.c);
  final AppController c;
  @override
  Widget build(BuildContext context) => _Page(
    title: 'Activity log',
    subtitle: 'Connection, source and failover events',
    child: Card(
      child: c.logs.isEmpty
          ? const Center(
              child: Text(
                'No events yet',
                style: TextStyle(color: Colors.white38),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(18),
              itemCount: c.logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(
                  c.logs[i],
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: Color(0xFFB8C4E8),
                  ),
                ),
              ),
            ),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });
  final String title, subtitle;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: Colors.white38)),
              ],
            ),
            const Spacer(),
            if (action != null) action!,
          ],
        ),
      ),
      const SizedBox(height: 18),
      Expanded(child: child),
    ],
  );
}

class _FormCard extends StatelessWidget {
  const _FormCard({
    required this.title,
    required this.hint,
    required this.controller,
    required this.button,
    required this.onTap,
  });
  final String title, hint, button;
  final TextEditingController controller;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            maxLines: 2,
            decoration: InputDecoration(hintText: hint),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.add_link),
              label: Text(button),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });
  final String title, suffix;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            Text(
              '${value.round()} $suffix',
              style: const TextStyle(color: cyan, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: (max - min).round(),
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(19),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: cyan, size: 19),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  color: Colors.white54,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          ...children,
        ],
      ),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: selected ? blue.withValues(alpha: .16) : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: selected ? cyan : Colors.white38, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white54,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size, required this.inverted});
  final double size;
  final bool inverted;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Transform.translate(
      offset: const Offset(0, 6),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(
          inverted ? const Color(0xFF101012) : Colors.white,
          BlendMode.srcIn,
        ),
        child: Image.asset('assets/brand_logo.png', fit: BoxFit.contain),
      ),
    ),
  );
}

class _WindowBar extends StatelessWidget {
  const _WindowBar();

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMaximize,
            child: const SizedBox.expand(),
          ),
        ),
        _WindowControlButton(
          icon: Icons.remove_rounded,
          onPressed: windowManager.minimize,
        ),
        _WindowControlButton(
          icon: Icons.crop_square_rounded,
          onPressed: _toggleMaximize,
        ),
        _WindowControlButton(
          icon: Icons.close_rounded,
          destructive: true,
          onPressed: windowManager.close,
        ),
        const SizedBox(width: 4),
      ],
    ),
  );
}

class _WindowControlButton extends StatelessWidget {
  const _WindowControlButton({
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => IconButton(
    constraints: const BoxConstraints.tightFor(width: 42, height: 36),
    padding: EdgeInsets.zero,
    splashRadius: 18,
    hoverColor: destructive
        ? const Color(0xFFB42335)
        : Colors.white.withValues(alpha: .06),
    color: Colors.white54,
    iconSize: 17,
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

class _ConnectButton extends StatefulWidget {
  const _ConnectButton({
    required this.active,
    required this.busy,
    required this.error,
    required this.onTap,
  });
  final bool active, busy, error;
  final VoidCallback onTap;

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<_ConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) _pulse.repeat();
  }

  @override
  void didUpdateWidget(covariant _ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.busy != widget.busy) {
      _transition.forward(from: 0);
    }
    if (widget.busy && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.busy && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? const Color(0xFF0B1018)
        : widget.error
        ? const Color(0xFFB8B8BC)
        : cyan;
    final targetSize = widget.active
        ? 190.0
        : widget.busy
        ? 182.0
        : 168.0;
    return AnimatedBuilder(
      animation: Listenable.merge([_pulse, _transition]),
      builder: (context, child) {
        final pulse = widget.busy
            ? .025 * (1 + sin(_pulse.value * 2 * pi))
            : 0.0;
        final bounce = sin(_transition.value * pi) * .07;
        return Transform.scale(scale: 1 + pulse + bounce, child: child);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          width: targetSize,
          height: targetSize,
          padding: EdgeInsets.all(widget.active ? 7 : 5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.active ? Colors.white : color.withValues(alpha: .12),
            border: Border.all(
              color: widget.active
                  ? Colors.white
                  : color.withValues(alpha: .58),
              width: widget.active ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(
                  alpha: widget.busy || widget.active ? .30 : 0,
                ),
                blurRadius: widget.busy || widget.active ? 38 : 0,
                spreadRadius: widget.busy ? 4 : 0,
              ),
            ],
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.active ? Colors.white : const Color(0xFF0B1018),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 280),
                  opacity: widget.busy ? .52 : 1,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 420),
                    scale: widget.active ? 1.08 : .92,
                    child: _BrandMark(size: 116, inverted: widget.active),
                  ),
                ),
                if (widget.busy)
                  SizedBox(
                    width: targetSize - 30,
                    height: targetSize - 30,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: color,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
