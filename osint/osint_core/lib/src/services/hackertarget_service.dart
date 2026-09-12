import 'package:http/http.dart' as http;

import '../models/source_result.dart';

/// A hostname paired with the address it resolved to.
class HostRecord {
  const HostRecord({required this.hostname, required this.address});

  final String hostname;
  final String address;
}

/// Queries HackerTarget's keyless host-discovery endpoints.
///
/// Complements Certificate Transparency: CT only knows hosts that were issued
/// a certificate, while this returns hosts observed in DNS. The two disagree
/// often enough that running both materially widens the discovered surface.
///
/// The free tier is rate-limited by source address and returns its limit
/// message as a 200 with a plain-text body, so the response text has to be
/// inspected rather than just the status code.
class HackerTargetService {
  HackerTargetService({
    http.Client? client,
    this.baseUrl = 'https://api.hackertarget.com',
    this.timeout = const Duration(seconds: 25),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'HackerTarget';

  /// Hosts known for [domain].
  Future<SourceResult<List<HostRecord>>> hostSearch(String domain) async {
    final uri = Uri.parse('$baseUrl/hostsearch/')
        .replace(queryParameters: {'q': domain});
    return _csv(uri, (fields) {
      if (fields.length < 2) return null;
      return HostRecord(
        hostname: fields[0].trim().toLowerCase(),
        address: fields[1].trim(),
      );
    });
  }

  /// Domains observed sharing [address].
  ///
  /// On shared hosting this returns every unrelated tenant too, so it is
  /// evidence of co-location, never of common ownership.
  Future<SourceResult<List<HostRecord>>> reverseIp(String address) async {
    final uri = Uri.parse('$baseUrl/reverseiplookup/')
        .replace(queryParameters: {'q': address});
    return _csv(uri, (fields) {
      final hostname = fields.first.trim().toLowerCase();
      if (hostname.isEmpty) return null;
      return HostRecord(hostname: hostname, address: address);
    });
  }

  Future<SourceResult<List<HostRecord>>> _csv(
    Uri uri,
    HostRecord? Function(List<String> fields) parse,
  ) async {
    try {
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode != 200) {
        return SourceFailure(sourceName, 'HTTP ${response.statusCode}');
      }

      final body = response.body.trim();
      final lower = body.toLowerCase();

      // The API reports its own errors in prose with a 200 status.
      if (lower.contains('api count exceeded') ||
          lower.contains('too many requests')) {
        return const SourceFailure(
          sourceName,
          'Free-tier daily quota exceeded',
        );
      }
      if (lower.startsWith('error') || lower.contains('invalid input')) {
        return SourceFailure(sourceName, body);
      }
      if (body.isEmpty || lower.contains('no records found')) {
        return const SourceEmpty(sourceName, 'No records found');
      }

      final records = <HostRecord>[];
      for (final line in body.split('\n')) {
        final text = line.trim();
        if (text.isEmpty) continue;
        final record = parse(text.split(','));
        if (record != null) records.add(record);
      }

      if (records.isEmpty) {
        return const SourceEmpty(sourceName, 'No parseable records');
      }
      return SourceSuccess(sourceName, records);
    } catch (error) {
      return SourceFailure(sourceName, 'Lookup failed: $error');
    }
  }

  void close() => _client.close();
}
