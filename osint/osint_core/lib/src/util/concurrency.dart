/// Maps [items] through [task], running at most [concurrency] tasks at once.
///
/// A brand sweep generates hundreds of typosquat candidates, each needing its
/// own DNS lookup. Firing them all at once gets the device rate-limited by the
/// resolver and starves the UI isolate of scheduling; running them one at a
/// time takes minutes. This keeps a fixed window in flight.
///
/// Results are returned in the same order as [items]. If [task] throws for an
/// item, the error propagates and remaining items are abandoned, so [task]
/// should return a result type rather than throw for expected failures.
Future<List<R>> mapWithConcurrency<T, R>(
  Iterable<T> items,
  Future<R> Function(T item) task, {
  int concurrency = 8,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }

  final queue = items.toList(growable: false);
  final results = List<R?>.filled(queue.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= queue.length) return;
      results[index] = await task(queue[index]);
    }
  }

  final workerCount = concurrency < queue.length ? concurrency : queue.length;
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);

  return [for (final result in results) result as R];
}
