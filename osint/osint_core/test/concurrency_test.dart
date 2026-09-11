import 'dart:async';

import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('mapWithConcurrency', () {
    test('preserves input order regardless of completion order', () async {
      // Later items finish first, so a naive implementation would reorder.
      final results = await mapWithConcurrency(
        [5, 4, 3, 2, 1],
        (item) async {
          await Future<void>.delayed(Duration(milliseconds: item * 10));
          return item * 2;
        },
        concurrency: 5,
      );
      expect(results, [10, 8, 6, 4, 2]);
    });

    test('never exceeds the concurrency limit', () async {
      var inFlight = 0;
      var peak = 0;

      await mapWithConcurrency(
        List.generate(20, (index) => index),
        (_) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return null;
        },
        concurrency: 3,
      );

      expect(peak, lessThanOrEqualTo(3));
      expect(peak, 3);
    });

    test('runs every item exactly once', () async {
      final seen = <int>[];
      await mapWithConcurrency(
        List.generate(50, (index) => index),
        (item) async {
          seen.add(item);
          return item;
        },
        concurrency: 7,
      );
      expect(seen, hasLength(50));
      expect(seen.toSet(), hasLength(50));
    });

    test('handles an empty input without spawning workers', () async {
      expect(await mapWithConcurrency(<int>[], (i) async => i), isEmpty);
    });

    test('handles concurrency greater than the item count', () async {
      final results =
          await mapWithConcurrency([1, 2], (i) async => i, concurrency: 99);
      expect(results, [1, 2]);
    });

    test('rejects a concurrency below one', () {
      expect(
        () => mapWithConcurrency([1], (i) async => i, concurrency: 0),
        throwsArgumentError,
      );
    });

    test('propagates an error thrown by the task', () async {
      await expectLater(
        mapWithConcurrency([1, 2, 3], (item) async {
          if (item == 2) throw StateError('boom');
          return item;
        }),
        throwsStateError,
      );
    });
  });
}
