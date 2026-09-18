import '../models/extracted_target.dart';
import '../models/target.dart';

/// Pulls OSINT targets out of free text — OCR output or a scanned code.
///
/// Written as pure, synchronous Dart with no plugin dependency so the part
/// most likely to be wrong (deciding what is and is not an indicator) can be
/// tested exhaustively without a camera or a device.
class TargetExtractor {
  const TargetExtractor({this.knownTlds = commonTlds, this.refang = true});

  /// Suffixes accepted as real TLDs.
  ///
  /// Without this check every filename in a screenshot becomes a domain:
  /// `report.pdf`, `logo.png` and `backup.zip` all satisfy the shape of a
  /// hostname. Supply the live IANA list for full coverage; the bundled set
  /// keeps the feature working offline.
  final Set<String> knownTlds;

  /// Whether to undo defanging before matching.
  final bool refang;

  /// A small offline TLD set: the common generic ones plus the ccTLDs that
  /// appear most in the region this tool is used in.
  static const Set<String> commonTlds = {
    'com',
    'net',
    'org',
    'edu',
    'gov',
    'mil',
    'int',
    'info',
    'biz',
    'io',
    'co',
    'me',
    'app',
    'dev',
    'xyz',
    'top',
    'site',
    'online',
    'shop',
    'store',
    'live',
    'cloud',
    'ai',
    'tech',
    'space',
    'club',
    'work',
    'my',
    'sg',
    'id',
    'th',
    'ph',
    'vn',
    'bn',
    'uk',
    'au',
    'nz',
    'jp',
    'kr',
    'cn',
    'hk',
    'tw',
    'in',
    'pk',
    'bd',
    'lk',
    'ru',
    'de',
    'fr',
    'nl',
    'it',
    'es',
    'pt',
    'pl',
    'se',
    'no',
    'fi',
    'dk',
    'ch',
    'at',
    'be',
    'ie',
    'cz',
    'gr',
    'tr',
    'ua',
    'ca',
    'us',
    'mx',
    'br',
    'ar',
    'cl',
    'za',
    'ng',
    'ke',
    'eg',
    'ae',
    'sa',
    'il',
    'tk',
    'ml',
    'ga',
    'cf',
    'gq',
    'cc',
    'ws',
    'to',
    'sh',
    'is',
    'eu',
    'asia',
    'pro',
  };

  static final RegExp _url = RegExp(
    r'\bhttps?://[^\s<>"'
    "'"
    r'\]\[)(,]+',
    caseSensitive: false,
  );

  static final RegExp _email = RegExp(
    r'\b[A-Za-z0-9._%+-]+@([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)\b',
  );

  static final RegExp _ipv4 = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');

  static final RegExp _hash = RegExp(
    r'\b(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{40}|[0-9a-fA-F]{32})\b',
  );

  static final RegExp _domain = RegExp(
    r'\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\b',
  );

  /// Undoes the conventions threat reports use to make indicators unclickable.
  ///
  /// Analysts write `hxxps://evil[.]com` and `192.168.1[.]1` precisely so a
  /// reader cannot fat-finger a live link. A screenshot of such a report is
  /// exactly the kind of image this feature is pointed at, so the text has to
  /// be put back into its real form before anything will match.
  static String refangText(String input) {
    var text = input;
    const bracketed = [
      ('[.]', '.'),
      ('(.)', '.'),
      ('{.}', '.'),
      (' [dot] ', '.'),
      ('[dot]', '.'),
      ('(dot)', '.'),
      ('[:]', ':'),
      ('[://]', '://'),
      ('[at]', '@'),
      ('(at)', '@'),
      (' [@] ', '@'),
    ];
    for (final (from, to) in bracketed) {
      text = text.replaceAll(from, to);
      text = text.replaceAll(from.toUpperCase(), to);
    }
    // replaceAll does not substitute capture groups in Dart — the scheme has
    // to be rebuilt from the match.
    text = text.replaceAllMapped(
      RegExp(r'\bhxxp(s?)(?::|\[:\])//', caseSensitive: false),
      (match) => 'http${match[1]!.toLowerCase()}://',
    );
    text = text.replaceAllMapped(
      RegExp(r'\bh\*\*p(s?)://', caseSensitive: false),
      (match) => 'http${match[1]!.toLowerCase()}://',
    );
    return text;
  }

  /// True when [text] carried any defanging marker.
  static bool looksDefanged(String text) => text != refangText(text);

  /// Extracts every distinct indicator from [text].
  ///
  /// Results are ordered by how specific the indicator is — hashes and IPs
  /// first, then URLs, then bare domains — because that is the order an
  /// analyst wants to triage them in.
  List<ExtractedTarget> fromText(
    String text, {
    TargetOrigin origin = TargetOrigin.text,
  }) {
    if (text.trim().isEmpty) return const [];

    final defanged = refang && looksDefanged(text);
    final source = refang ? refangText(text) : text;

    // Spans already claimed by a more specific match, so a URL's host is not
    // reported a second time as a bare domain.
    final claimed = <({int start, int end})>[];
    bool isClaimed(int start, int end) =>
        claimed.any((span) => start >= span.start && end <= span.end);
    void claim(int start, int end) => claimed.add((start: start, end: end));

    final found = <String, ExtractedTarget>{};

    void record(String raw, Target target, {bool fromEmail = false}) {
      if (target.kind == TargetKind.unknown) return;
      final existing = found[target.value];
      if (existing != null) {
        found[target.value] = existing.copyWith(
          occurrences: existing.occurrences + 1,
        );
        return;
      }
      found[target.value] = ExtractedTarget(
        target: target,
        raw: raw,
        origin: origin,
        wasDefanged: defanged,
        fromEmail: fromEmail,
      );
    }

    // Hashes first: they are unambiguous and cannot overlap anything else.
    for (final match in _hash.allMatches(source)) {
      claim(match.start, match.end);
      record(match[0]!, Target.parse(match[0]!));
    }

    // URLs next, claiming their whole span so the host is not re-reported.
    for (final match in _url.allMatches(source)) {
      if (isClaimed(match.start, match.end)) continue;
      claim(match.start, match.end);
      final raw = _trimTrailingPunctuation(match[0]!);
      record(raw, Target.parse(raw));
    }

    for (final match in _email.allMatches(source)) {
      if (isClaimed(match.start, match.end)) continue;
      claim(match.start, match.end);
      final domain = match[1]!;
      final target = Target.parse(domain);
      if (_hasKnownTld(target)) record(domain, target, fromEmail: true);
    }

    for (final match in _ipv4.allMatches(source)) {
      if (isClaimed(match.start, match.end)) continue;
      final target = Target.parse(match[0]!);
      if (target.kind != TargetKind.ipv4) continue;
      claim(match.start, match.end);
      record(match[0]!, target);
    }

    for (final match in _domain.allMatches(source)) {
      if (isClaimed(match.start, match.end)) continue;
      final target = Target.parse(match[0]!);
      if (!_hasKnownTld(target)) continue;
      claim(match.start, match.end);
      record(match[0]!, target);
    }

    final results = found.values.toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    return results;
  }

  /// Extracts indicators from a scanned code's payload.
  ///
  /// A QR code is usually one URL, but campaign codes carry tracking
  /// parameters and occasionally several links, so the payload goes through
  /// the same extraction rather than being trusted wholesale.
  List<ExtractedTarget> fromCode(String payload) =>
      fromText(payload, origin: TargetOrigin.code);

  /// Whether a parsed domain ends in a TLD this extractor recognises.
  ///
  /// IPs, hashes and URLs bypass the check — only bare domains can be
  /// confused with filenames.
  bool _hasKnownTld(Target target) {
    if (target.kind != TargetKind.domain) return true;
    final parts = target.value.split('.');
    if (parts.length < 2) return false;
    return knownTlds.contains(parts.last);
  }

  /// Strips punctuation OCR and prose leave hanging off a URL.
  static String _trimTrailingPunctuation(String value) {
    var text = value;
    while (text.isNotEmpty && '.,;:!?)]}>"\''.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  static int _rank(ExtractedTarget extracted) =>
      switch (extracted.target.kind) {
        TargetKind.sha256 => 0,
        TargetKind.sha1 => 1,
        TargetKind.md5 => 2,
        TargetKind.ipv4 => 3,
        TargetKind.ipv6 => 4,
        TargetKind.url => 5,
        TargetKind.domain => 6,
        TargetKind.unknown => 7,
      };
}
