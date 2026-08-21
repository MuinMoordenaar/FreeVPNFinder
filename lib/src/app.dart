import 'dart:ui';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';

const bg = Color(0xFF070B17),
    panel = Color(0xFF10172A),
    blue = Color(0xFF5B7CFF),
    cyan = Color(0xFF35D8FF);

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
        bodyColor: const Color(0xFFDDE5FF),
        displayColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        color: panel.withValues(alpha: .78),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Color(0x1FFFFFFF)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0B1122),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
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
    (Icons.shield_rounded, 'Connect'),
    (Icons.radar_rounded, 'Sources'),
    (Icons.add_link_rounded, 'Profiles'),
    (Icons.tune_rounded, 'Settings'),
    (Icons.terminal_rounded, 'Logs'),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, __) {
      final c = widget.controller;
      return Scaffold(
        body: Stack(
          children: [
            const Positioned(
              top: -180,
              left: 180,
              child: _Glow(color: blue, size: 520),
            ),
            const Positioned(
              bottom: -240,
              right: -80,
              child: _Glow(color: Color(0xFF752CFF), size: 560),
            ),
            SafeArea(
              child: Row(
                children: [
                  Container(
                    width: 210,
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.symmetric(
                      vertical: 22,
                      horizontal: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xC90D1427),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            SizedBox(width: 4),
                            _MiniLogo(),
                            SizedBox(width: 11),
                            Expanded(
                              child: Text(
                                'Free VPN\nFinder',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  height: 1.05,
                                  fontSize: 17,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 34),
                        for (var i = 0; i < nav.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: _NavItem(
                              icon: nav[i].$1,
                              label: nav[i].$2,
                              selected: page == i,
                              onTap: () => setState(() => page = i),
                            ),
                          ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .035),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                c.connected
                                    ? Icons.lock_rounded
                                    : Icons.lock_open_rounded,
                                size: 18,
                                color: c.connected
                                    ? const Color(0xFF50E3A4)
                                    : Colors.white38,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  c.connected ? 'Protected' : 'Not protected',
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
                      padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
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
        Row(
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your private connection',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 4),
                Text(
                  'One click to find and keep a working route',
                  style: TextStyle(color: Colors.white38),
                ),
              ],
            ),
            const Spacer(),
            DropdownButtonHideUnderline(
              child: DropdownButton<ConnectionMode>(
                value: c.settings.mode,
                borderRadius: BorderRadius.circular(14),
                dropdownColor: const Color(0xFF111A30),
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
                                ? const Color(0xFF50E3A4)
                                : busy
                                ? cyan
                                : c.phase == AppPhase.error
                                ? const Color(0xFFFF6B7B)
                                : Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          c.activeNode?.name ??
                              (busy
                                  ? 'Testing node ${c.tested}'
                                  : 'Press F to connect'),
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
                    Expanded(
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
                    Expanded(
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
                          const Spacer(),
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
      Row(
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
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
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

class _MiniLogo extends StatelessWidget {
  const _MiniLogo();
  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [blue, Color(0xFF8B5CFF)]),
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(color: blue.withValues(alpha: .35), blurRadius: 18),
      ],
    ),
    child: const Text(
      'F',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
  );
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.active,
    required this.busy,
    required this.error,
    required this.onTap,
  });
  final bool active, busy, error;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final color = active
        ? const Color(0xFF50E3A4)
        : error
        ? const Color(0xFFFF6B7B)
        : cyan;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: 178,
        height: 178,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [color.withValues(alpha: .85), blue],
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: .28),
              blurRadius: busy ? 50 : 28,
              spreadRadius: busy ? 6 : 1,
            ),
          ],
        ),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF0B1224),
          ),
          child: Center(
            child: busy
                ? SizedBox(
                    width: 66,
                    height: 66,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: color,
                    ),
                  )
                : Text(
                    'F',
                    style: TextStyle(
                      fontSize: 74,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      foreground: Paint()
                        ..shader = const LinearGradient(
                          colors: [Colors.white, cyan],
                        ).createShader(const Rect.fromLTWH(0, 0, 90, 90)),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: .12),
      ),
    ),
  );
}
