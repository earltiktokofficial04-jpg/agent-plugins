import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ioc_verdict.dart';
import '../models/source_result.dart';
import '../models/target.dart';
import 'api_key_provider.dart';

/// Queries AbuseIPDB for community abuse reports against an IP address.
class AbuseIpdbService {
  AbuseIpdbService({
    required ApiKeyProvider keys,
    http.Client? client,
    this.baseUrl = 'https://api.abuseipdb.com/api/v2',
    this.timeout = const Duration(seconds: 20),
    this.maxAgeInDays = 90,
  })  : _keys = keys,
        _client = client ?? http.Client();

  final ApiKeyProvider _keys;
  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  /// How far back to consider reports. Older reports say little about whether
  /// an address is hostile today, since cloud IPs are recycled constantly.
  final int maxAgeInDays;

  static const String sourceName = 'AbuseIPDB';

  /// Checks [target], which must be an IP address.
  Future<SourceResult<IocVerdict>> check(Target target) async {
    if (!target.isIp) {
      return const SourceEmpty(sourceName, 'Only IP addresses are supported');
    }

    final key = await _keys.keyFor(ApiKeySource.abuseIpdb);
    if (key == null || key.isEmpty) {
      return const SourceFailure(
        sourceName,
        'No AbuseIPDB API key configured',
        needsApiKey: true,
      );
    }

    final uri = Uri.parse('$baseUrl/check').replace(queryParameters: {
      'ipAddress': target.value,
      'maxAgeInDays': maxAgeInDays.toString(),
    });

    try {
      final response = await _client.get(uri, headers: {
        'Key': key,
        'Accept': 'application/json',
      }).timeout(timeout);

      if (response.statusCode == 401) {
        return const SourceFailure(
          sourceName,
          'AbuseIPDB rejected the API key',
          needsApiKey: true,
        );
      }
      if (response.statusCode == 429) {
        return const SourceFailure(
          sourceName,
          'AbuseIPDB daily quota exhausted',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'AbuseIPDB returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        return const SourceEmpty(sourceName, 'No data for this address');
      }

      final score = (data['abuseConfidenceScore'] as int?) ?? 0;
      final reports = (data['totalReports'] as int?) ?? 0;

      // AbuseIPDB publishes confidence as a percentage. The thresholds follow
      // their own guidance: 25 is worth a look, 75 is worth blocking.
      final IocSeverity severity;
      if (score >= 75) {
        severity = IocSeverity.malicious;
      } else if (score >= 25) {
        severity = IocSeverity.suspicious;
      } else {
        severity = IocSeverity.clean;
      }

      final details = <String, String>{};
      void put(String label, String field) {
        final value = data[field];
        if (value is String && value.isNotEmpty) details[label] = value;
      }

      put('Country', 'countryCode');
      put('ISP', 'isp');
      put('Domain', 'domain');
      put('Usage type', 'usageType');
      if (data['isTor'] == true) details['Tor exit node'] = 'yes';
      if (data['isWhitelisted'] == true) details['Whitelisted'] = 'yes';

      return SourceSuccess(
        sourceName,
        IocVerdict(
          source: sourceName,
          severity: severity,
          score: score,
          detections: reports,
          details: details,
        ),
      );
    } catch (error) {
      return SourceFailure(sourceName, 'AbuseIPDB lookup failed: $error');
    }
  }

  void close() => _client.close();
}
