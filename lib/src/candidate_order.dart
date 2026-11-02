import 'dart:collection';

import 'models.dart';

/// Keeps previously proven nodes first, then samples every source across its
/// entire list instead of exhausting one subscription from top to bottom.
List<VpnNode> orderAndroidCandidates(Iterable<VpnNode> candidates) {
  final all = candidates.toList();
  final proven = all.where((node) => node.successCount > 0).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final unknownBySource = <String, List<VpnNode>>{};
  for (final node in all.where((node) => node.successCount == 0)) {
    unknownBySource.putIfAbsent(node.sourceId, () => []).add(node);
  }

  final queues = [
    for (final group in unknownBySource.values)
      Queue<VpnNode>.from(_midpointOrder(group)),
  ];
  final result = <VpnNode>[...proven];
  while (queues.any((queue) => queue.isNotEmpty)) {
    for (final queue in queues) {
      if (queue.isNotEmpty) result.add(queue.removeFirst());
    }
  }
  return result;
}

List<VpnNode> _midpointOrder(List<VpnNode> nodes) {
  if (nodes.length < 2) return nodes;
  final ranges = Queue<({int start, int end})>()
    ..add((start: 0, end: nodes.length));
  final result = <VpnNode>[];
  while (ranges.isNotEmpty) {
    final range = ranges.removeFirst();
    if (range.start >= range.end) continue;
    final middle = (range.start + range.end) ~/ 2;
    result.add(nodes[middle]);
    if (range.start < middle) {
      ranges.add((start: range.start, end: middle));
    }
    if (middle + 1 < range.end) {
      ranges.add((start: middle + 1, end: range.end));
    }
  }
  return result;
}
