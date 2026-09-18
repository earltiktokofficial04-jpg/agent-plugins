import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dns_record.dart';
import '../models/source_result.dart';

/// Resolves DNS records over HTTPS.
///
/// DNS-over-HTTPS is used in preference to a raw UDP resolver for three
/// reasons: it needs no native socket permissions on Android, it works on
/// mobile networks that hijack port 53, and it is plain JSON over the same
/// HTTP client every other source already uses.
class DnsOverHttpsService {
  DnsOverHttpsService({
    http.Client? client,
    this.endpoint = cloudflare,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Resolver endpoint, expected to speak the JSON DoH dialect.
  final String endpoint;

  final Duration timeout;

  static const String cloudflare = 'https://cloudflare-dns.com/dns-query';
  static const String google = 'https://dns.google/resolve';

  static const String sourceName = 'DNS';

  /// Resolves a single record [type] for [name].
  ///
  /// Returns [SourceEmpty] for NXDOMAIN or an empty answer section, which is
  /// a meaningful result rather than an error — an unregistered typosquat
  /// candidate is exactly this case.
  Future<SourceResult<List<DnsRecord>>> resolve(
    String name,
    DnsRecordType type,
  ) async {
    final uri = Uri.parse(
      endpoint,
    ).replace(queryParameters: {'name': name, 'type': type.code.toString()});

    try {
      final response = await _client
          .get(uri, headers: {'Accept': 'application/dns-json'})
          .timeout(timeout);

      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'Resolver returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected resolver payload');
      }

      // RCODE 3 is NXDOMAIN: the name definitively does not exist.
      final status = decoded['Status'];
      if (status == 3) {
        return const SourceEmpty(sourceName, 'NXDOMAIN');
      }
      if (status != 0) {
        return SourceFailure(sourceName, 'Resolver RCODE $status');
      }

      final answers = decoded['Answer'];
      if (answers is! List || answers.isEmpty) {
        return const SourceEmpty(sourceName, 'No answer section');
      }

      final records = <DnsRecord>[];
      for (final answer in answers) {
        if (answer is! Map<String, dynamic>) continue;
        final code = answer['type'];
        final recordType = code is int ? DnsRecordType.fromCode(code) : null;
        if (recordType == null) continue;
        // Resolvers return the whole chain: an A query for a CNAME'd host
        // answers with the CNAME *and* the final A. Keeping both would report
        // the CNAME target as if it were an address.
        if (recordType != type) continue;
        records.add(
          DnsRecord(
            name: (answer['name'] as String?) ?? name,
            type: recordType,
            data: _unquote((answer['data'] as String?) ?? ''),
            ttl: (answer['TTL'] as int?) ?? 0,
          ),
        );
      }

      if (records.isEmpty) {
        return const SourceEmpty(
          sourceName,
          'No records of the requested type',
        );
      }
      return SourceSuccess(sourceName, records);
    } catch (error) {
      return SourceFailure(sourceName, 'Lookup failed: $error');
    }
  }

  /// Resolves several record types concurrently.
  ///
  /// Returns a [SourceResult] rather than a bare list so a caller cannot
  /// mistake "the resolver is down" for "this domain has no records" — the
  /// two are identical in a flattened list and opposite in meaning.
  ///
  /// Success when any type returned records; empty when every type answered
  /// but none held any; failure only when every lookup failed.
  Future<SourceResult<List<DnsRecord>>> resolveAll(
    String name,
    List<DnsRecordType> types,
  ) async {
    if (types.isEmpty) return const SourceEmpty(sourceName, 'No types asked');

    final results = await Future.wait(types.map((type) => resolve(name, type)));

    final records = <DnsRecord>[];
    var anyAnswered = false;
    String? firstFailure;

    for (final result in results) {
      switch (result) {
        case SourceSuccess(:final value):
          anyAnswered = true;
          records.addAll(value);
        case SourceEmpty():
          anyAnswered = true;
        case SourceFailure(:final message):
          firstFailure ??= message;
      }
    }

    if (records.isNotEmpty) return SourceSuccess(sourceName, records);
    if (anyAnswered) {
      return const SourceEmpty(sourceName, 'No records of any queried type');
    }
    return SourceFailure(
      sourceName,
      'Every lookup failed: ${firstFailure ?? 'unknown error'}',
    );
  }

  /// TXT records arrive wrapped in quotes; strip one balanced pair.
  static String _unquote(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  void close() => _client.close();
}
