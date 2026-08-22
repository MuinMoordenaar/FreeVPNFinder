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
