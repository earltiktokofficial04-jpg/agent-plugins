import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/certificate.dart';
import '../models/source_result.dart';

/// Queries the crt.sh Certificate Transparency log aggregator.
///
/// Needs no API key. crt.sh is slow and rate-limits aggressively, so the
/// timeout here is deliberately generous and callers should query it once per
/// target rather than per subdomain.
class CrtShService {
  CrtShService({
    http.Client? client,
    this.baseUrl = 'https://crt.sh',
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'crt.sh';

  /// Fetches every logged certificate covering [domain] or its subdomains.
  ///
  /// The `%.` wildcard asks crt.sh for subdomain matches as well as the apex.
  Future<SourceResult<List<CtCertificate>>> certificates(String domain) async {
    final uri = Uri.parse(baseUrl).replace(
      queryParameters: {'q': '%.$domain', 'output': 'json'},
    );

    try {
      final response = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(timeout);

      if (response.statusCode == 429) {
        return const SourceFailure(
          sourceName,
          'Rate limited by crt.sh — retry in a minute',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'crt.sh returned HTTP ${response.statusCode}',
        );
      }
      if (response.body.trim().isEmpty) {
        return const SourceEmpty(sourceName, 'No logged certificates');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        return const SourceFailure(sourceName, 'Unexpected crt.sh payload');
      }
      if (decoded.isEmpty) {
        return const SourceEmpty(sourceName, 'No logged certificates');
      }

      final certificates = <CtCertificate>[];
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        // name_value packs every SAN entry into one newline-delimited string.
        final nameValue = (entry['name_value'] as String?) ?? '';
        final names = nameValue
            .split('\n')
            .map((name) => name.trim().toLowerCase())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList();

        certificates.add(
          CtCertificate(
            issuer: (entry['issuer_name'] as String?) ?? '',
            commonName: (entry['common_name'] as String?) ?? '',
            names: names,
            notBefore: _parseDate(entry['not_before']),
            notAfter: _parseDate(entry['not_after']),
            serialNumber: (entry['serial_number'] as String?) ?? '',
          ),
        );
      }

      return SourceSuccess(sourceName, certificates);
    } catch (error) {
      return SourceFailure(sourceName, 'crt.sh query failed: $error');
    }
  }

  /// Extracts the distinct subdomains of [domain] from [certificates].
  ///
  /// Wildcard entries are unwrapped to their parent so that `*.api.foo.com`
  /// reports the real, useful host `api.foo.com`. Names outside [domain] are
  /// discarded: a shared certificate can legitimately cover unrelated hosts,
  /// and reporting those as the target's assets would be wrong.
  static List<String> subdomainsFrom(
    String domain,
    List<CtCertificate> certificates,
  ) {
    final suffix = '.${domain.toLowerCase()}';
    final hosts = <String>{};

    for (final certificate in certificates) {
      for (var name in certificate.names) {
        if (name.startsWith('*.')) name = name.substring(2);
        if (name == domain.toLowerCase() || name.endsWith(suffix)) {
          hosts.add(name);
        }
      }
    }

    final sorted = hosts.toList()..sort();
    return sorted;
  }

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  void close() => _client.close();
}
