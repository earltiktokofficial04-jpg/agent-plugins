import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ioc_verdict.dart';
import '../models/source_result.dart';
import '../models/target.dart';
import 'api_key_provider.dart';

/// Queries VirusTotal v3 for the reputation of a domain, IP or file hash.
class VirusTotalService {
  VirusTotalService({
    required ApiKeyProvider keys,
    http.Client? client,
    this.baseUrl = 'https://www.virustotal.com/api/v3',
    this.timeout = const Duration(seconds: 20),
  })  : _keys = keys,
        _client = client ?? http.Client();

  final ApiKeyProvider _keys;
  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'VirusTotal';

  /// Looks up [target] and converts the analysis stats into a verdict.
  ///
  /// Only domains, IPs, URLs and hashes are supported; anything else returns
  /// [SourceEmpty] rather than a failure, because "this source does not apply
  /// to this target" is not an error worth showing as one.
  Future<SourceResult<IocVerdict>> lookup(Target target) async {
    final path = switch (target.kind) {
      TargetKind.domain || TargetKind.url => 'domains/${target.value}',
      TargetKind.ipv4 || TargetKind.ipv6 => 'ip_addresses/${target.value}',
      TargetKind.md5 ||
      TargetKind.sha1 ||
      TargetKind.sha256 =>
        'files/${target.value}',
      TargetKind.unknown => null,
    };
    if (path == null) {
      return const SourceEmpty(sourceName, 'Target type not supported');
    }

    final key = await _keys.keyFor(ApiKeySource.virusTotal);
    if (key == null || key.isEmpty) {
      return const SourceFailure(
        sourceName,
        'No VirusTotal API key configured',
        needsApiKey: true,
      );
    }

    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/$path'), headers: {'x-apikey': key})
          .timeout(timeout);

      if (response.statusCode == 404) {
        return const SourceEmpty(sourceName, 'Not present in VirusTotal');
      }
      if (response.statusCode == 401) {
        return const SourceFailure(
          sourceName,
          'VirusTotal rejected the API key',
          needsApiKey: true,
        );
      }
      if (response.statusCode == 429) {
        return const SourceFailure(
          sourceName,
          'VirusTotal quota exhausted — the free tier allows 4 lookups/minute',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'VirusTotal returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        return const SourceEmpty(sourceName, 'No data for this indicator');
      }
      final attributes = data['attributes'];
      if (attributes is! Map<String, dynamic>) {
        return const SourceEmpty(sourceName, 'No attributes for this indicator');
      }

      return SourceSuccess(sourceName, _verdict(attributes));
    } catch (error) {
      return SourceFailure(sourceName, 'VirusTotal lookup failed: $error');
    }
  }

  static IocVerdict _verdict(Map<String, dynamic> attributes) {
    final stats = attributes['last_analysis_stats'];
    var malicious = 0;
    var suspicious = 0;
    var harmless = 0;
    var undetected = 0;
    if (stats is Map<String, dynamic>) {
      malicious = (stats['malicious'] as int?) ?? 0;
      suspicious = (stats['suspicious'] as int?) ?? 0;
      harmless = (stats['harmless'] as int?) ?? 0;
      undetected = (stats['undetected'] as int?) ?? 0;
    }
    final total = malicious + suspicious + harmless + undetected;

    // Two or more malicious detections is treated as malicious; a single
    // detection is downgraded to suspicious, because lone hits from low-quality
    // engines are the dominant source of false positives in VirusTotal.
    final IocSeverity severity;
    if (malicious >= 2) {
      severity = IocSeverity.malicious;
    } else if (malicious == 1 || suspicious > 0) {
      severity = IocSeverity.suspicious;
    } else if (total > 0) {
      severity = IocSeverity.clean;
    } else {
      severity = IocSeverity.unknown;
    }

    final details = <String, String>{};
    final reputation = attributes['reputation'];
    if (reputation is int) details['Community score'] = '$reputation';
    final registrar = attributes['registrar'];
    if (registrar is String && registrar.isNotEmpty) {
      details['Registrar'] = registrar;
    }
    final asOwner = attributes['as_owner'];
    if (asOwner is String && asOwner.isNotEmpty) details['AS owner'] = asOwner;
    final country = attributes['country'];
    if (country is String && country.isNotEmpty) details['Country'] = country;
    final fileType = attributes['type_description'];
    if (fileType is String && fileType.isNotEmpty) {
      details['File type'] = fileType;
    }

    return IocVerdict(
      source: sourceName,
      severity: severity,
      detections: malicious + suspicious,
      totalEngines: total,
      details: details,
    );
  }

  void close() => _client.close();
}
