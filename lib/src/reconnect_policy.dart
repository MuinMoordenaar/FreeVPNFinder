import 'models.dart';

List<VpnNode> recentConnectionCandidates(
  VpnNode? preferred,
  Iterable<VpnNode> backups,
) {
  final seen = <String>{};
  return [
    if (preferred != null && seen.add(preferred.fingerprint)) preferred,
    for (final node in backups)
      if (seen.add(node.fingerprint)) node,
  ];
}

int latencyOrder(VpnNode a, VpnNode b) =>
    (a.latency ?? 1 << 30).compareTo(b.latency ?? 1 << 30);

VpnNode lowestLatencyNode(Iterable<VpnNode> nodes) =>
    nodes.reduce((a, b) => latencyOrder(a, b) <= 0 ? a : b);
