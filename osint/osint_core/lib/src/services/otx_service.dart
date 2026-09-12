import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ioc_verdict.dart';
import '../models/source_result.dart';
import '../models/target.dart';

/// Queries AlienVault OTX, the open threat-exchange community database.
///
/// The general endpoint answers without a key, which makes OTX the only
/// community reputation source in the tool that works out of the box.
class OtxService {
  OtxService({
    http.Client? client,
    this.baseUrl = 'https://otx.alienvault.com/api/v1',
    this.timeout = const Duration(seconds: 25),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'AlienVault OTX';

  /// Looks [target] up and converts pulse membership into a verdict.
  Future<SourceResult<IocVerdict>> lookup(Target target) async {
    final path = switch (target.kind) {
      TargetKind.domain || TargetKind.url => 'indicators/domain/${target.value}',
      TargetKind.ipv4 => 'indicators/IPv4/${target.value}',
      TargetKind.ipv6 => 'indicators/IPv6/${target.value}',
      TargetKind.md5 ||
      TargetKind.sha1 ||
      TargetKind.sha256 =>
        'indicators/file/${target.value}',
      TargetKind.unknown => null,
    };
    if (path == null) {
      return const SourceEmpty(sourceName, 'Target type not supported');
    }

    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/$path/general'))
          .timeout(timeout);

      if (response.statusCode == 404) {
        return const SourceEmpty(sourceName, 'Not present in OTX');
      }
      if (response.statusCode != 200) {
        return SourceFailure(sourceName, 'HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }

      return SourceSuccess(sourceName, _verdict(decoded));
    } catch (error) {
      return SourceFailure(sourceName, 'OTX lookup failed: $error');
    }
  }

  /// Whitelist entries OTX attaches to well-known indicators.
  ///
  /// These matter more than they look. A popular domain accumulates dozens of
  /// pulses simply by appearing in reports — example.com carries 50 — so pulse
  /// count alone would flag most of the internet's best-known hosts as
  /// malicious. A whitelist entry means OTX itself vouches for the indicator,
  /// and caps the severity accordingly.
  static bool _isWhitelisted(Map<String, dynamic> json) {
    final validation = json['validation'];
    if (validation is! List) return false;
    for (final entry in validation) {
      if (entry is! Map<String, dynamic>) continue;
      final source = (entry['source'] as String?)?.toLowerCase() ?? '';
      final name = (entry['name'] as String?)?.toLowerCase() ?? '';
      if (source.contains('whitelist') ||
          name.contains('whitelist') ||
          source == 'majestic' ||
          source == 'akamai') {
        return true;
      }
    }
    return false;
  }

  static IocVerdict _verdict(Map<String, dynamic> json) {
    final pulseInfo = json['pulse_info'];
    var pulseCount = 0;
    if (pulseInfo is Map<String, dynamic>) {
      pulseCount = (pulseInfo['count'] as int?) ?? 0;
    }

    final whitelisted = _isWhitelisted(json);

    final IocSeverity severity;
    if (whitelisted) {
      // Vouched-for indicators are reported as clean regardless of pulse
      // count, with the count still shown so the analyst can judge.
      severity = IocSeverity.clean;
    } else if (pulseCount >= 5) {
      severity = IocSeverity.malicious;
    } else if (pulseCount >= 1) {
      severity = IocSeverity.suspicious;
    } else {
      severity = IocSeverity.clean;
    }

    final details = <String, String>{};
    if (whitelisted) {
      details['Whitelisted'] = 'yes — OTX vouches for this indicator';
    }
    void put(String label, String field) {
      final value = json[field];
      if (value is String && value.isNotEmpty) details[label] = value;
    }

    put('ASN', 'asn');
    put('Country', 'country_name');
    put('City', 'city');
    final reputation = json['reputation'];
    if (reputation is int && reputation != 0) {
      details['Reputation'] = '$reputation';
    }

    return IocVerdict(
      source: sourceName,
      severity: severity,
      detections: pulseCount,
      details: details,
    );
  }

  /// Historical hostname/address pairings OTX has observed.
  ///
  /// Passive DNS answers the question active DNS cannot: where did this domain
  /// point *before* today. Coverage on the keyless endpoint is patchy, so an
  /// empty result is common and is reported as empty rather than as an error.
  Future<SourceResult<List<PassiveDnsRecord>>> passiveDns(
    Target target,
  ) async {
    final path = switch (target.kind) {
      TargetKind.domain || TargetKind.url => 'indicators/domain/${target.value}',
      TargetKind.ipv4 => 'indicators/IPv4/${target.value}',
      TargetKind.unknown ||
      TargetKind.ipv6 ||
      TargetKind.md5 ||
      TargetKind.sha1 ||
      TargetKind.sha256 =>
        null,
    };
    if (path == null) {
      return const SourceEmpty(sourceName, 'Target type not supported');
    }

    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/$path/passive_dns'))
          .timeout(timeout);

      if (response.statusCode != 200) {
        return SourceFailure(sourceName, 'HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }
      final records = decoded['passive_dns'];
      if (records is! List || records.isEmpty) {
        return const SourceEmpty(sourceName, 'No passive DNS history');
      }

      final parsed = <PassiveDnsRecord>[];
      for (final record in records) {
        if (record is! Map<String, dynamic>) continue;
        parsed.add(
          PassiveDnsRecord(
            hostname: (record['hostname'] as String?) ?? '',
            address: (record['address'] as String?) ?? '',
            recordType: (record['record_type'] as String?) ?? '',
            firstSeen: DateTime.tryParse((record['first'] as String?) ?? ''),
            lastSeen: DateTime.tryParse((record['last'] as String?) ?? ''),
          ),
        );
      }

      return SourceSuccess(sourceName, parsed);
    } catch (error) {
      return SourceFailure(sourceName, 'Passive DNS lookup failed: $error');
    }
  }

  void close() => _client.close();
}

/// One historical hostname-to-address observation.
class PassiveDnsRecord {
  const PassiveDnsRecord({
    required this.hostname,
    required this.address,
    this.recordType = '',
    this.firstSeen,
    this.lastSeen,
  });

  final String hostname;
  final String address;
  final String recordType;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
}
