import '../models/typosquat.dart';

/// Generates domains that visually or typographically resemble a brand domain.
///
/// Every candidate is produced by mutating only the registrable label, never
/// the suffix, except for [TyposquatTechnique.tldSwap] which varies only the
/// suffix. The generator is deliberately pure and synchronous: it performs no
/// network access, so it is cheap to test exhaustively and the caller decides
/// which candidates are worth a DNS lookup.
class TyposquatGenerator {
  const TyposquatGenerator({this.extraTlds = defaultTlds});

  /// Suffixes tried for [TyposquatTechnique.tldSwap].
  final List<String> extraTlds;

  /// TLDs that disproportionately host impersonation domains, plus the common
  /// legitimate ones a brand is most likely to be confused with.
  static const List<String> defaultTlds = [
    'com', 'net', 'org', 'co', 'io', 'app', 'shop', 'online', 'site',
    'xyz', 'top', 'live', 'info', 'biz', 'cc', 'my', 'com.my',
  ];

  /// Keys physically adjacent on a QWERTY keyboard, used for fat-finger
  /// replacement and insertion mutations.
  static const Map<String, String> _adjacency = {
    'a': 'qwsz', 'b': 'vghn', 'c': 'xdfv', 'd': 'serfcx', 'e': 'wsdr',
    'f': 'drtgvc', 'g': 'ftyhbv', 'h': 'gyujnb', 'i': 'ujko', 'j': 'huikmn',
    'k': 'jiolm', 'l': 'kop', 'm': 'njk', 'n': 'bhjm', 'o': 'iklp',
    'p': 'ol', 'q': 'wa', 'r': 'edft', 's': 'awedxz', 't': 'rfgy',
    'u': 'yhji', 'v': 'cfgb', 'w': 'qase', 'x': 'zsdc', 'y': 'tghu',
    'z': 'asx',
    '0': 'o9', '1': 'l2', '2': '13', '3': '24', '4': '35',
    '5': '46', '6': '57', '7': '68', '8': '79', '9': '80',
  };

  /// Characters that render similarly enough to be mistaken at a glance.
  static const Map<String, List<String>> _homoglyphs = {
    'a': ['4'],
    'b': ['6'],
    'c': ['e'],
    'd': ['cl'],
    'e': ['c', '3'],
    'g': ['9', 'q'],
    'i': ['1', 'l', 'j'],
    'l': ['1', 'i'],
    'm': ['rn', 'nn'],
    'n': ['m', 'r'],
    'o': ['0'],
    'q': ['g'],
    's': ['5'],
    'u': ['v'],
    'v': ['u'],
    'w': ['vv'],
    'z': ['2'],
    '0': ['o'],
    '1': ['l', 'i'],
  };

  /// Splits [domain] into its registrable label and suffix.
  ///
  /// Handles the common two-part suffixes (`co.uk`, `com.my`, ...) that a naive
  /// split on the last dot would mangle into a label of `co`, which would
  /// generate nonsense candidates.
  static ({String label, String suffix}) splitDomain(String domain) {
    const twoPartSuffixes = {
      'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.my', 'net.my', 'org.my',
      'gov.my', 'edu.my', 'com.au', 'net.au', 'org.au', 'com.sg', 'com.br',
      'co.jp', 'co.kr', 'co.nz', 'co.za', 'com.cn', 'com.tr',
    };
    final parts = domain.split('.');
    if (parts.length < 2) return (label: domain, suffix: '');
    final lastTwo = parts.sublist(parts.length - 2).join('.');
    if (parts.length >= 3 && twoPartSuffixes.contains(lastTwo)) {
      return (label: parts[parts.length - 3], suffix: lastTwo);
    }
    return (label: parts[parts.length - 2], suffix: parts.last);
  }

  /// Produces every candidate for [domain], de-duplicated.
  ///
  /// The original domain is never returned as its own candidate. Candidates
  /// are ordered by technique so that the higher-signal techniques
  /// (homoglyph, transposition) appear before the noisier ones.
  List<TyposquatCandidate> generate(String domain) {
    final normalised = domain.trim().toLowerCase();
    final split = splitDomain(normalised);
    final label = split.label;
    final suffix = split.suffix;
    if (label.isEmpty || suffix.isEmpty) return const [];

    final seen = <String>{normalised};
    final candidates = <TyposquatCandidate>[];

    void add(String mutatedLabel, TyposquatTechnique technique) {
      if (!_isRegistrableLabel(mutatedLabel)) return;
      final candidate = '$mutatedLabel.$suffix';
      if (seen.add(candidate)) {
        candidates.add(
          TyposquatCandidate(domain: candidate, technique: technique),
        );
      }
    }

    for (final mutation in _homoglyphMutations(label)) {
      add(mutation, TyposquatTechnique.homoglyph);
    }
    for (final mutation in _transpositions(label)) {
      add(mutation, TyposquatTechnique.transposition);
    }
    for (final mutation in _replacements(label)) {
      add(mutation, TyposquatTechnique.replacement);
    }
    for (final mutation in _omissions(label)) {
      add(mutation, TyposquatTechnique.omission);
    }
    for (final mutation in _insertions(label)) {
      add(mutation, TyposquatTechnique.insertion);
    }
    for (final mutation in _repetitions(label)) {
      add(mutation, TyposquatTechnique.repetition);
    }
    for (final mutation in _hyphenations(label)) {
      add(mutation, TyposquatTechnique.hyphenation);
    }
    for (final mutation in _bitsquats(label)) {
      add(mutation, TyposquatTechnique.bitsquatting);
    }
    for (final prefixed in _prefixes(label)) {
      add(prefixed, TyposquatTechnique.prefix);
    }

    // TLD swaps keep the label intact and vary the suffix instead.
    for (final tld in extraTlds) {
      if (tld == suffix) continue;
      final candidate = '$label.$tld';
      if (seen.add(candidate)) {
        candidates.add(
          TyposquatCandidate(
            domain: candidate,
            technique: TyposquatTechnique.tldSwap,
          ),
        );
      }
    }

    return candidates;
  }

  Iterable<String> _omissions(String label) sync* {
    if (label.length <= 2) return;
    for (var i = 0; i < label.length; i++) {
      yield label.substring(0, i) + label.substring(i + 1);
    }
  }

  Iterable<String> _repetitions(String label) sync* {
    for (var i = 0; i < label.length; i++) {
      final char = label[i];
      if (char == '-') continue;
      yield label.substring(0, i) + char + label.substring(i);
    }
  }

  Iterable<String> _transpositions(String label) sync* {
    for (var i = 0; i < label.length - 1; i++) {
      if (label[i] == label[i + 1]) continue;
      yield label.substring(0, i) +
          label[i + 1] +
          label[i] +
          label.substring(i + 2);
    }
  }

  Iterable<String> _replacements(String label) sync* {
    for (var i = 0; i < label.length; i++) {
      for (final replacement in _adjacency[label[i]]?.split('') ?? const <String>[]) {
        yield label.substring(0, i) + replacement + label.substring(i + 1);
      }
    }
  }

  Iterable<String> _insertions(String label) sync* {
    for (var i = 0; i < label.length; i++) {
      for (final inserted in _adjacency[label[i]]?.split('') ?? const <String>[]) {
        yield label.substring(0, i) + inserted + label.substring(i);
      }
    }
  }

  Iterable<String> _homoglyphMutations(String label) sync* {
    for (var i = 0; i < label.length; i++) {
      for (final glyph in _homoglyphs[label[i]] ?? const <String>[]) {
        yield label.substring(0, i) + glyph + label.substring(i + 1);
      }
    }
  }

  Iterable<String> _hyphenations(String label) sync* {
    for (var i = 1; i < label.length; i++) {
      if (label[i] == '-' || label[i - 1] == '-') continue;
      yield '${label.substring(0, i)}-${label.substring(i)}';
    }
  }

  /// Flips each low bit of each character, the classic bitsquatting attack
  /// against memory errors in resolvers and clients.
  Iterable<String> _bitsquats(String label) sync* {
    const allowed = 'abcdefghijklmnopqrstuvwxyz0123456789-';
    for (var i = 0; i < label.length; i++) {
      final code = label.codeUnitAt(i);
      for (var bit = 0; bit < 5; bit++) {
        final flipped = String.fromCharCode(code ^ (1 << bit));
        if (!allowed.contains(flipped)) continue;
        yield label.substring(0, i) + flipped + label.substring(i + 1);
      }
    }
  }

  /// True when [label] could actually be registered as a DNS label.
  ///
  /// Mutations — bitsquatting especially — can produce strings that are not
  /// valid hostnames. Checking them would waste a DNS lookup per candidate and
  /// surface nonsense in the findings list, so they are dropped at the source.
  static bool _isRegistrableLabel(String label) {
    if (label.isEmpty || label.length > 63) return false;
    if (label.startsWith('-') || label.endsWith('-')) return false;
    for (final unit in label.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLower = unit >= 0x61 && unit <= 0x7a;
      final isHyphen = unit == 0x2d;
      if (!isDigit && !isLower && !isHyphen) return false;
    }
    return true;
  }

  /// Prepends and appends the words impersonation domains most often bolt on.
  Iterable<String> _prefixes(String label) sync* {
    const affixes = [
      'login', 'secure', 'account', 'verify', 'support', 'my', 'portal',
      'auth', 'billing', 'update',
    ];
    for (final affix in affixes) {
      yield '$affix-$label';
      yield '$label-$affix';
    }
  }
}
