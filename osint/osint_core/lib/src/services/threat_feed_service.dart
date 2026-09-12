import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_result.dart';
import '../models/threat_feed.dart';
import '../util/ip_range.dart';
import '../util/lenient_body.dart';

/// A downloaded feed, parsed and indexed for membership testing.
class LoadedFeed {
  const LoadedFeed({
    required this.feed,
    required this.blocks,
    required this.fetchedAt,
  });

  final ThreatFeed feed;
  final CidrSet blocks;
  final DateTime fetchedAt;

  /// How many blocks or addresses the feed listed.
  int get entryCount => blocks.length;
}

/// Downloads and caches bulk threat feeds.
///
/// Feeds are flat files of tens of thousands of lines with no query API, so
/// they are fetched whole and searched locally. A fetched feed is cached for
/// [cacheFor]: the underlying lists are rebuilt hourly at best, and
/// re-downloading megabytes per indicator would be both slow and rude to the
/// people hosting them for free.
class ThreatFeedService {
  ThreatFeedService({
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
    this.cacheFor = const Duration(hours: 6),
    DateTime Function() now = DateTime.now,
  })  : _client = client ?? http.Client(),
        _now = now;

  final http.Client _client;
  final Duration timeout;
  final Duration cacheFor;
  final DateTime Function() _now;

  final Map<String, LoadedFeed> _cache = {};

  /// Feeds currently held in cache.
  Iterable<LoadedFeed> get cached => _cache.values;

  /// Total entries across every cached feed.
  int get cachedEntryCount =>
      _cache.values.fold(0, (total, feed) => total + feed.entryCount);

  /// Fetches [feed], returning the cached copy when it is still fresh.
  Future<SourceResult<LoadedFeed>> load(
    ThreatFeed feed, {
    bool forceRefresh = false,
  }) async {
    final cachedFeed = _cache[feed.id];
    if (!forceRefresh &&
        cachedFeed != null &&
        _now().difference(cachedFeed.fetchedAt) < cacheFor) {
      return SourceSuccess(feed.name, cachedFeed);
    }

    try {
      final response =
          await _client.get(Uri.parse(feed.url)).timeout(timeout);

      if (response.statusCode != 200) {
        return SourceFailure(feed.name, 'HTTP ${response.statusCode}');
      }

      final blocks = CidrSet.parse(
        const LineSplitter().convert(decodeBodyLeniently(response)),
      );
      if (blocks.isEmpty) {
        // Several of these feeds legitimately empty out when the threat they
        // track goes quiet, which is a finding rather than a fault.
        return SourceEmpty(feed.name, 'Feed is currently empty');
      }

      final loaded = LoadedFeed(
        feed: feed,
        blocks: blocks,
        fetchedAt: _now(),
      );
      _cache[feed.id] = loaded;
      return SourceSuccess(feed.name, loaded);
    } catch (error) {
      return SourceFailure(feed.name, 'Fetch failed: $error');
    }
  }

  /// Drops every cached feed.
  void clearCache() => _cache.clear();

  void close() => _client.close();
}
