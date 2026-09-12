import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_result.dart';
import '../util/lenient_body.dart';

/// One TLD's authoritative RDAP server, from the IANA bootstrap file.
class RdapServiceEntry {
  const RdapServiceEntry({required this.tlds, required this.serverUrl});

  final List<String> tlds;

  /// Base URL of the registry's own RDAP server.
  final String serverUrl;
}

/// The IANA RDAP bootstrap, indexed for lookup.
class RdapBootstrap {
  RdapBootstrap(this.entries) {
    for (final entry in entries) {
      for (final tld in entry.tlds) {
        _byTld[tld.toLowerCase()] = entry.serverUrl;
      }
    }
  }

  final List<RdapServiceEntry> entries;
  final Map<String, String> _byTld = {};

  /// Distinct registry servers, which is the meaningful source count: many
  /// TLDs share one operator's server.
  int get serverCount =>
      entries.map((entry) => entry.serverUrl).toSet().length;

  /// TLDs with a published RDAP server.
  int get tldCount => _byTld.length;

  /// The authoritative RDAP base URL for [domain], or null when its TLD
  /// publishes none.
  String? serverFor(String domain) {
    final parts = domain.toLowerCase().split('.');
    if (parts.length < 2) return null;
    return _byTld[parts.last];
  }
}

/// A Certificate Transparency log.
class CtLog {
  const CtLog({required this.url, required this.operator, this.description = ''});

  final String url;
  final String operator;
  final String description;
}

/// Fetches the published registries the catalogue is built from.
///
/// These are not OSINT data sources themselves — they are the authoritative
/// lists that say which sources exist. Each is published by the body that
/// governs it (IANA for TLDs and RDAP, Mozilla for the Public Suffix List,
/// Google for the CT log list), so the counts are verifiable rather than
/// asserted.
class IanaRegistryService {
  IanaRegistryService({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.tldListUrl = 'https://data.iana.org/TLD/tlds-alpha-by-domain.txt',
    this.publicSuffixUrl =
        'https://publicsuffix.org/list/public_suffix_list.dat',
    this.rdapBootstrapUrl = 'https://data.iana.org/rdap/dns.json',
    this.ctLogListUrl =
        'https://www.gstatic.com/ct/log_list/v3/all_logs_list.json',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final String tldListUrl;
  final String publicSuffixUrl;
  final String rdapBootstrapUrl;
  final String ctLogListUrl;

  static const String tldSource = 'IANA TLD list';
  static const String suffixSource = 'Public Suffix List';
  static const String rdapSource = 'IANA RDAP bootstrap';
  static const String ctSource = 'CT log list';

  /// Every delegated top-level domain.
  Future<SourceResult<List<String>>> tlds() async {
    return _text(tldListUrl, tldSource, (body) {
      final tlds = <String>[];
      for (final line in const LineSplitter().convert(body)) {
        final text = line.trim();
        // The first line is a version comment.
        if (text.isEmpty || text.startsWith('#')) continue;
        tlds.add(text.toLowerCase());
      }
      return tlds;
    });
  }

  /// Every public suffix: the registrable namespaces a domain can live under.
  ///
  /// Wildcard (`*.`) and exception (`!`) rules are normalised to the suffix
  /// they describe, because a sweep targets `example.<suffix>` and cannot use
  /// the rule syntax directly.
  Future<SourceResult<List<String>>> publicSuffixes() async {
    return _text(publicSuffixUrl, suffixSource, (body) {
      final suffixes = <String>[];
      for (final line in const LineSplitter().convert(body)) {
        var text = line.trim();
        if (text.isEmpty || text.startsWith('//')) continue;
        if (text.startsWith('!')) text = text.substring(1);
        if (text.startsWith('*.')) text = text.substring(2);
        if (text.isEmpty) continue;
        suffixes.add(text.toLowerCase());
      }
      return suffixes;
    });
  }

  /// The RDAP bootstrap: which registry server is authoritative for which TLD.
  Future<SourceResult<RdapBootstrap>> rdapBootstrap() async {
    return _json(rdapBootstrapUrl, rdapSource, (decoded) {
      if (decoded is! Map<String, dynamic>) return null;
      final services = decoded['services'];
      if (services is! List) return null;

      final entries = <RdapServiceEntry>[];
      for (final service in services) {
        // Each entry is [[tld, ...], [url, ...]].
        if (service is! List || service.length < 2) continue;
        final tldList = service[0];
        final urlList = service[1];
        if (tldList is! List || urlList is! List || urlList.isEmpty) continue;

        final tlds = <String>[];
        for (final tld in tldList) {
          if (tld is String && tld.isNotEmpty) tlds.add(tld.toLowerCase());
        }
        // Prefer the HTTPS endpoint where a registry publishes both.
        final url = urlList.firstWhere(
          (candidate) => candidate is String && candidate.startsWith('https'),
          orElse: () => urlList.first,
        );
        if (tlds.isEmpty || url is! String) continue;
        entries.add(RdapServiceEntry(tlds: tlds, serverUrl: url));
      }
      return entries.isEmpty ? null : RdapBootstrap(entries);
    });
  }

  /// Every recognised Certificate Transparency log.
  Future<SourceResult<List<CtLog>>> ctLogs() async {
    return _json(ctLogListUrl, ctSource, (decoded) {
      if (decoded is! Map<String, dynamic>) return null;
      final operators = decoded['operators'];
      if (operators is! List) return null;

      final logs = <CtLog>[];
      for (final operator in operators) {
        if (operator is! Map<String, dynamic>) continue;
        final name = (operator['name'] as String?) ?? '';
        final operatorLogs = operator['logs'];
        if (operatorLogs is! List) continue;
        for (final log in operatorLogs) {
          if (log is! Map<String, dynamic>) continue;
          final url = log['url'];
          if (url is! String || url.isEmpty) continue;
          logs.add(
            CtLog(
              url: url,
              operator: name,
              description: (log['description'] as String?) ?? '',
            ),
          );
        }
      }
      return logs.isEmpty ? null : logs;
    });
  }

  Future<SourceResult<T>> _text<T>(
    String url,
    String source,
    T Function(String body) parse,
  ) async {
    try {
      final response =
          await _client.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode != 200) {
        return SourceFailure(source, 'HTTP ${response.statusCode}');
      }
      final parsed = parse(decodeBodyLeniently(response));
      if (parsed is List && parsed.isEmpty) {
        return SourceEmpty(source, 'List was empty');
      }
      return SourceSuccess(source, parsed);
    } catch (error) {
      return SourceFailure(source, 'Fetch failed: $error');
    }
  }

  Future<SourceResult<T>> _json<T>(
    String url,
    String source,
    T? Function(Object? decoded) parse,
  ) async {
    try {
      final response =
          await _client.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode != 200) {
        return SourceFailure(source, 'HTTP ${response.statusCode}');
      }
      final parsed = parse(jsonDecode(decodeBodyLeniently(response)));
      if (parsed == null) {
        return SourceFailure(source, 'Unexpected payload shape');
      }
      return SourceSuccess(source, parsed);
    } catch (error) {
      return SourceFailure(source, 'Fetch failed: $error');
    }
  }

  void close() => _client.close();
}
