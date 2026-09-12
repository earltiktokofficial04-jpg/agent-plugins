import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

const _high = ThreatFeed(
  id: 'high',
  name: 'High feed',
  url: 'https://example.test/high.txt',
  severity: FeedSeverity.high,
  description: 'x',
);
const _medium = ThreatFeed(
  id: 'medium',
  name: 'Medium feed',
  url: 'https://example.test/medium.txt',
  severity: FeedSeverity.medium,
  description: 'x',
);
const _contextual = ThreatFeed(
  id: 'contextual',
  name: 'Contextual feed',
  url: 'https://example.test/context.txt',
  severity: FeedSeverity.contextual,
  description: 'x',
);

BlocklistRepository _repository(Map<String, String> bodies) =>
    BlocklistRepository(
      feedService: ThreatFeedService(
        client: MockClient((request) async {
          final body = bodies[request.url.path];
          if (body == null) return http.Response('', 404);
          return http.Response(body, 200);
        }),
      ),
      feeds: const [_high, _medium, _contextual],
    );

void main() {
  group('BlocklistRepository', () {
    test('reports hits from every feed that lists the address', () async {
      final repository = _repository({
        '/high.txt': '1.2.3.0/24\n',
        '/medium.txt': '1.2.3.4\n',
        '/context.txt': '9.9.9.9\n',
      });

      final report = await repository.check(Target.parse('1.2.3.4'));

      expect(report.feedsChecked, 3);
      expect(report.hits, hasLength(2));
      expect(report.entriesSearched, 3);
      expect(report.isListedBySeriousFeed, isTrue);
      expect(report.worstSeverity, FeedSeverity.high);
    });

    test('orders hits with the strongest evidence first', () async {
      final repository = _repository({
        '/high.txt': '1.2.3.0/24\n',
        '/medium.txt': '1.2.3.0/24\n',
        '/context.txt': '1.2.3.0/24\n',
      });

      final report = await repository.check(Target.parse('1.2.3.4'));
      expect(
        report.hits.map((hit) => hit.feed.severity).toList(),
        [FeedSeverity.high, FeedSeverity.medium, FeedSeverity.contextual],
      );
    });

    test('a contextual-only hit is not treated as serious', () async {
      // A Tor exit should not read the same as a Spamhaus DROP listing.
      final repository = _repository({
        '/high.txt': '9.9.9.9\n',
        '/medium.txt': '9.9.9.9\n',
        '/context.txt': '1.2.3.4\n',
      });

      final report = await repository.check(Target.parse('1.2.3.4'));
      expect(report.hits, hasLength(1));
      expect(report.isListedBySeriousFeed, isFalse);
      expect(report.worstSeverity, FeedSeverity.contextual);
    });

    test('reports a clean address with no hits', () async {
      final repository = _repository({
        '/high.txt': '9.9.9.0/24\n',
        '/medium.txt': '8.8.8.8\n',
        '/context.txt': '7.7.7.7\n',
      });

      final report = await repository.check(Target.parse('1.2.3.4'));
      expect(report.hits, isEmpty);
      expect(report.feedsChecked, 3);
      expect(report.worstSeverity, isNull);
    });

    test('counts only the feeds that actually loaded', () async {
      // A failed download must not inflate the corpus the UI reports as
      // searched, or a thin check reads as a thorough one.
      final repository = _repository({
        '/high.txt': '1.2.3.0/24\n',
        // medium and contextual 404.
      });

      final report = await repository.check(Target.parse('1.2.3.4'));
      expect(report.feedsChecked, 1);
      expect(report.entriesSearched, 1);
      expect(report.notes.where((note) => !note.ok), hasLength(2));
    });

    test('refuses a non-IPv4 target with an explanatory note', () async {
      final repository = _repository({});
      final report = await repository.check(Target.parse('example.com'));
      expect(report.hits, isEmpty);
      expect(report.feedsChecked, 0);
      expect(report.notes.single.ok, isFalse);
      expect(report.notes.single.message, contains('IPv4'));
    });

    test('reports progress for each feed loaded', () async {
      final repository = _repository({
        '/high.txt': '1.2.3.0/24\n',
        '/medium.txt': '1.2.3.0/24\n',
        '/context.txt': '1.2.3.0/24\n',
      });

      final progress = <int>[];
      await repository.check(
        Target.parse('1.2.3.4'),
        concurrency: 1,
        onProgress: (loaded, total) {
          progress.add(loaded);
          expect(total, 3);
        },
      );
      expect(progress, [1, 2, 3]);
    });
  });
}
