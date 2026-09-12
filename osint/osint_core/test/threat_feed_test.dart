import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

const _feed = ThreatFeed(
  id: 'test_feed',
  name: 'Test feed',
  url: 'https://example.test/feed.txt',
  severity: FeedSeverity.high,
  description: 'x',
);

void main() {
  group('ThreatFeedService', () {
    test('downloads and indexes a feed', () async {
      final service = ThreatFeedService(
        client: MockClient(
          (_) async => http.Response('1.2.3.0/24\n5.6.7.8\n', 200),
        ),
      );

      final result = await service.load(_feed);
      final loaded = result.valueOrNull!;
      expect(loaded.entryCount, 2);
      expect(loaded.blocks.contains('1.2.3.99'), isTrue);
      expect(loaded.blocks.contains('5.6.7.8'), isTrue);
    });

    test('survives a malformed Content-Type header', () async {
      // GreenSnow really does send "charset: UTF-8" with a colon, which makes
      // http.Response.body throw. Losing a whole feed to a punctuation error
      // in someone's server config is not acceptable.
      final service = ThreatFeedService(
        client: MockClient(
          (_) async => http.Response.bytes(
            Uint8List.fromList(utf8.encode('9.9.9.0/24\n')),
            200,
            headers: {
              'content-type': 'text/plain; charset: UTF-8;charset=UTF-8',
            },
          ),
        ),
      );

      final result = await service.load(_feed);
      expect(result, isA<SourceSuccess<LoadedFeed>>());
      expect(result.valueOrNull!.blocks.contains('9.9.9.1'), isTrue);
    });

    test('reports an empty feed as empty, not as a failure', () async {
      // Several feeds legitimately empty out when the threat goes quiet.
      final service = ThreatFeedService(
        client: MockClient(
          (_) async => http.Response('# no entries today\n', 200),
        ),
      );
      final result = await service.load(_feed);
      expect(result, isA<SourceEmpty<LoadedFeed>>());
    });

    test('reports a non-200 as a failure', () async {
      final service = ThreatFeedService(
        client: MockClient((_) async => http.Response('', 503)),
      );
      final result = await service.load(_feed);
      expect(result, isA<SourceFailure<LoadedFeed>>());
      expect((result as SourceFailure<LoadedFeed>).message, contains('503'));
    });

    test('serves a cached copy while it is fresh', () async {
      var fetches = 0;
      var clock = DateTime.utc(2026);
      final service = ThreatFeedService(
        client: MockClient((_) async {
          fetches++;
          return http.Response('1.2.3.0/24\n', 200);
        }),
        cacheFor: const Duration(hours: 6),
        now: () => clock,
      );

      await service.load(_feed);
      await service.load(_feed);
      expect(fetches, 1, reason: 'second load should hit the cache');

      clock = clock.add(const Duration(hours: 7));
      await service.load(_feed);
      expect(fetches, 2, reason: 'stale cache should refetch');
    });

    test('forceRefresh bypasses a fresh cache', () async {
      var fetches = 0;
      final service = ThreatFeedService(
        client: MockClient((_) async {
          fetches++;
          return http.Response('1.2.3.0/24\n', 200);
        }),
        now: () => DateTime.utc(2026),
      );

      await service.load(_feed);
      await service.load(_feed, forceRefresh: true);
      expect(fetches, 2);
    });

    test('clearCache drops cached feeds', () async {
      final service = ThreatFeedService(
        client: MockClient((_) async => http.Response('1.2.3.0/24\n', 200)),
      );
      await service.load(_feed);
      expect(service.cachedEntryCount, 1);
      service.clearCache();
      expect(service.cachedEntryCount, 0);
    });
  });

  group('ThreatFeeds registry', () {
    test('every bundled feed has a unique id and an https url', () {
      final ids = <String>{};
      for (final feed in ThreatFeeds.all) {
        expect(ids.add(feed.id), isTrue, reason: 'duplicate id ${feed.id}');
        expect(feed.url, startsWith('https://'), reason: feed.id);
        expect(feed.name, isNotEmpty);
        expect(feed.description, isNotEmpty);
      }
    });

    test('byId finds a feed and returns null for an unknown one', () {
      expect(ThreatFeeds.byId('tor_exits')?.name, 'Tor exit nodes');
      expect(ThreatFeeds.byId('nope'), isNull);
    });

    test('Tor exits are classed as contextual, not malicious', () {
      // Running a Tor exit is not an accusation; classing it as malicious
      // would make the tool cry wolf on every privacy-conscious user.
      expect(
        ThreatFeeds.byId('tor_exits')!.severity,
        FeedSeverity.contextual,
      );
      expect(
        ThreatFeeds.byId('spamhaus_drop')!.severity,
        FeedSeverity.high,
      );
    });
  });
}
