/// An IPv4 CIDR block, used to test blocklist membership.
///
/// Threat feeds publish netblocks rather than individual addresses — Spamhaus
/// DROP lists /24s and larger — so membership testing needs real prefix
/// arithmetic, not string matching. Comparing textually would miss every
/// address in a listed block except the network address itself.
class Ipv4Cidr {
  const Ipv4Cidr._(this.network, this.prefixLength, this.raw);

  /// The network address as a 32-bit integer.
  final int network;

  final int prefixLength;

  /// The block exactly as the feed published it.
  final String raw;

  /// Parses `a.b.c.d/n`, or a bare address as a /32.
  ///
  /// Returns null rather than throwing: feed files contain comments, blank
  /// lines and occasional malformed entries, and one bad line must not abort
  /// the ingestion of a 5,000-line list.
  static Ipv4Cidr? tryParse(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;

    final slash = text.indexOf('/');
    final addressPart = slash == -1 ? text : text.substring(0, slash);
    final prefixPart = slash == -1 ? '32' : text.substring(slash + 1);

    final address = ipv4ToInt(addressPart);
    if (address == null) return null;

    final prefix = int.tryParse(prefixPart);
    if (prefix == null || prefix < 0 || prefix > 32) return null;

    final mask = _maskFor(prefix);
    return Ipv4Cidr._(address & mask, prefix, text);
  }

  /// True when [address], given as a 32-bit integer, falls inside this block.
  bool containsInt(int address) => (address & _maskFor(prefixLength)) == network;

  /// True when [address] parses as IPv4 and falls inside this block.
  bool contains(String address) {
    final value = ipv4ToInt(address);
    return value != null && containsInt(value);
  }

  /// Converts dotted-quad IPv4 to a 32-bit integer, or null when invalid.
  ///
  /// Rejects zero-padded octets, which different resolvers interpret as either
  /// decimal or octal — an ambiguity that has been used to slip addresses past
  /// naive blocklist checks.
  static int? ipv4ToInt(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;

    var result = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      if (part.length > 1 && part.startsWith('0')) return null;
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      result = (result << 8) | octet;
    }
    return result;
  }

  static int _maskFor(int prefixLength) =>
      prefixLength == 0 ? 0 : (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;

  @override
  String toString() => raw;
}

/// An indexed set of CIDR blocks supporting fast membership tests.
///
/// A feed can hold tens of thousands of blocks and is checked once per
/// indicator, so blocks are bucketed by prefix length: a lookup tests each
/// distinct length present rather than walking every block. With the handful
/// of prefix lengths real feeds use, that turns a linear scan into a few hash
/// lookups.
class CidrSet {
  CidrSet(Iterable<Ipv4Cidr> blocks) {
    for (final block in blocks) {
      _byPrefix.putIfAbsent(block.prefixLength, () => <int, Ipv4Cidr>{})
          [block.network] = block;
    }
    _prefixLengths = _byPrefix.keys.toList()..sort();
  }

  /// Parses [lines] from a feed file, skipping comments and malformed entries.
  factory CidrSet.parse(Iterable<String> lines) {
    final blocks = <Ipv4Cidr>[];
    for (final line in lines) {
      // Feeds comment with ';' (Spamhaus) or '#' (most others), sometimes
      // trailing the data on the same line.
      var text = line;
      for (final marker in [';', '#']) {
        final index = text.indexOf(marker);
        if (index != -1) text = text.substring(0, index);
      }
      final block = Ipv4Cidr.tryParse(text);
      if (block != null) blocks.add(block);
    }
    return CidrSet(blocks);
  }

  final Map<int, Map<int, Ipv4Cidr>> _byPrefix = {};
  late final List<int> _prefixLengths;

  /// Number of blocks held.
  int get length =>
      _byPrefix.values.fold(0, (total, blocks) => total + blocks.length);

  /// True when the set holds no blocks.
  bool get isEmpty => _byPrefix.isEmpty;

  /// The block containing [address], or null when it is not listed.
  ///
  /// Checks the most specific prefixes first, so the returned block is the
  /// tightest match rather than an arbitrary one.
  Ipv4Cidr? match(String address) {
    final value = Ipv4Cidr.ipv4ToInt(address);
    if (value == null) return null;

    for (final prefixLength in _prefixLengths.reversed) {
      final mask = Ipv4Cidr._maskFor(prefixLength);
      final block = _byPrefix[prefixLength]![value & mask];
      if (block != null) return block;
    }
    return null;
  }

  /// True when [address] is listed.
  bool contains(String address) => match(address) != null;
}
