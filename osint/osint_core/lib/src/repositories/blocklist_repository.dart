import '../models/reports.dart';
import '../models/target.dart';
import '../models/threat_feed.dart';
import '../services/threat_feed_service.dart';
import '../util/concurrency.dart';

/// The result of checking one address against every configured feed.
class BlocklistReport {
  const BlocklistReport({
    required this.address,
    this.hits = const [],
    this.feedsChecked = 0,
    this.entriesSearched = 0,
    this.notes = const [],
  });

  final String address;

  /// Feeds that list this address, worst severity first.
  final List<FeedHit> hits;

  final int feedsChecked;

  /// Total blocks and addresses searched across every feed that loaded.
  ///
  /// Reported so the UI can show the size of the corpus actually consulted,
  /// rather than the size it would have been had every feed loaded.
  final int entriesSearched;

  final List<SourceNote> notes;

  /// True when a feed of at least medium severity lists the address.
  bool get isListedBySeriousFeed =>
      hits.any((hit) => hit.feed.severity != FeedSeverity.contextual);

  /// The worst severity among the feeds that matched.
  FeedSeverity? get worstSeverity {
    FeedSeverity? worst;
    for (final hit in hits) {
      if (worst == null || hit.feed.severity.index < worst.index) {
        worst = hit.feed.severity;
      }
    }
    return worst;
  }
}

/// Checks an address against the bundled public threat feeds.
class BlocklistRepository {
  BlocklistRepository({
    required ThreatFeedService feedService,
    List<ThreatFeed> feeds = ThreatFeeds.all,
  })  : _feedService = feedService,
        _feeds = feeds;

  final ThreatFeedService _feedService;
  final List<ThreatFeed> _feeds;

  /// Feeds this repository consults.
  List<ThreatFeed> get feeds => List.unmodifiable(_feeds);

  /// Checks [target], which must be an IPv4 address.
  ///
  /// Feeds are fetched concurrently but with a small window: these are free,
  /// volunteer-hosted files, several of them megabytes, and hammering them all
  /// at once is both slow on mobile and inconsiderate.
  Future<BlocklistReport> check(
    Target target, {
    int concurrency = 3,
    void Function(int loaded, int total)? onProgress,
  }) async {
    if (target.kind != TargetKind.ipv4) {
      return BlocklistReport(
        address: target.value,
        notes: const [
          SourceNote(
            source: 'Blocklists',
            ok: false,
            message: 'Feed matching supports IPv4 addresses only',
          ),
        ],
      );
    }

    var loaded = 0;
    final results = await mapWithConcurrency(
      _feeds,
      (feed) async {
        final result = await _feedService.load(feed);
        loaded++;
        onProgress?.call(loaded, _feeds.length);
        return result;
      },
      concurrency: concurrency,
    );

    final hits = <FeedHit>[];
    final notes = <SourceNote>[];
    var entriesSearched = 0;
    var feedsChecked = 0;

    for (final result in results) {
      notes.add(SourceNote.from(result));
      final loadedFeed = result.valueOrNull;
      if (loadedFeed == null) continue;

      feedsChecked++;
      entriesSearched += loadedFeed.entryCount;

      final match = loadedFeed.blocks.match(target.value);
      if (match != null) {
        hits.add(
          FeedHit(feed: loadedFeed.feed, matchedBlock: match.raw),
        );
      }
    }

    // Strongest evidence first; FeedSeverity is declared worst-to-least.
    hits.sort(
      (a, b) => a.feed.severity.index.compareTo(b.feed.severity.index),
    );

    return BlocklistReport(
      address: target.value,
      hits: hits,
      feedsChecked: feedsChecked,
      entriesSearched: entriesSearched,
      notes: notes,
    );
  }
}
