/// What a feed lists, which decides how a lookup matches against it.
enum FeedKind {
  /// Individual IPv4 addresses or CIDR blocks.
  ipv4,
}

/// How confidently a hit in this feed condemns an address.
///
/// Feeds differ enormously in what listing means. Spamhaus DROP lists netblocks
/// wholly controlled by criminals; blocklist.de lists addresses that attacked
/// someone's SSH last week and may be an innocent, since-cleaned host. Treating
/// every hit alike would make the tool cry wolf.
enum FeedSeverity {
  /// A hit is strong evidence: hijacked or criminal-controlled space.
  high,

  /// A hit is worth attention: recent attack or C2 activity.
  medium,

  /// A hit is contextual, not an accusation: Tor exits, scanner noise.
  contextual,
}

/// A public bulk threat feed, fetched whole and searched locally.
class ThreatFeed {
  const ThreatFeed({
    required this.id,
    required this.name,
    required this.url,
    required this.severity,
    required this.description,
    this.kind = FeedKind.ipv4,
  });

  final String id;
  final String name;
  final String url;
  final FeedSeverity severity;
  final String description;
  final FeedKind kind;
}

/// The bundled feed registry.
///
/// Every entry was verified to respond and to parse. Feeds are fetched whole
/// rather than queried per indicator: they are published as flat files with no
/// lookup API, and one download serves any number of local checks.
abstract final class ThreatFeeds {
  static const List<ThreatFeed> all = [
    ThreatFeed(
      id: 'spamhaus_drop',
      name: 'Spamhaus DROP',
      url: 'https://www.spamhaus.org/drop/drop.txt',
      severity: FeedSeverity.high,
      description:
          'Netblocks Spamhaus assesses as wholly controlled by criminals or '
          'hijacked. A hit here is about as strong as a public feed gets.',
    ),
    ThreatFeed(
      id: 'feodo_c2',
      name: 'Feodo Tracker C2',
      url: 'https://feodotracker.abuse.ch/downloads/ipblocklist.txt',
      severity: FeedSeverity.high,
      description: 'Botnet command-and-control servers tracked by abuse.ch.',
    ),
    ThreatFeed(
      id: 'sslbl_botnet',
      name: 'SSLBL botnet C2',
      url: 'https://sslbl.abuse.ch/blacklist/sslipblacklist.txt',
      severity: FeedSeverity.high,
      description:
          'Addresses serving TLS certificates associated with botnet C2.',
    ),
    ThreatFeed(
      id: 'emerging_threats',
      name: 'Emerging Threats compromised',
      url:
          'https://rules.emergingthreats.net/blockrules/compromised-ips.txt',
      severity: FeedSeverity.medium,
      description: 'Hosts observed compromised and used in attacks.',
    ),
    ThreatFeed(
      id: 'cinsscore',
      name: 'CINS Army list',
      url: 'https://cinsscore.com/list/ci-badguys.txt',
      severity: FeedSeverity.medium,
      description:
          'Addresses with a poor reputation score across the CINS sensor '
          'network.',
    ),
    ThreatFeed(
      id: 'greensnow',
      name: 'GreenSnow',
      url: 'https://blocklist.greensnow.co/greensnow.txt',
      severity: FeedSeverity.medium,
      description: 'Hosts observed brute-forcing or probing services.',
    ),
    ThreatFeed(
      id: 'dshield',
      name: 'DShield recommended block',
      url: 'https://feeds.dshield.org/block.txt',
      severity: FeedSeverity.medium,
      description:
          'The /24s generating the most attack traffic seen by the SANS '
          'Internet Storm Center.',
    ),
    ThreatFeed(
      id: 'blocklist_de',
      name: 'blocklist.de',
      url: 'https://lists.blocklist.de/lists/all.txt',
      severity: FeedSeverity.contextual,
      description:
          'Addresses reported for attacks in the last 48 hours. Large and '
          'noisy — a hit means recent bad behaviour, not necessarily a bad '
          'host today.',
    ),
    ThreatFeed(
      id: 'tor_exits',
      name: 'Tor exit nodes',
      url: 'https://check.torproject.org/torbulkexitlist',
      severity: FeedSeverity.contextual,
      description:
          'Current Tor exit relays. Not malicious — context for why traffic '
          'from this address is anonymised.',
    ),
  ];

  /// The feed with [id], or null.
  static ThreatFeed? byId(String id) {
    for (final feed in all) {
      if (feed.id == id) return feed;
    }
    return null;
  }
}

/// A hit against one feed.
class FeedHit {
  const FeedHit({
    required this.feed,
    required this.matchedBlock,
  });

  final ThreatFeed feed;

  /// The listed block or address that matched, so the finding can be shown
  /// exactly as the feed published it.
  final String matchedBlock;
}
