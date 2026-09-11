import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_result.dart';
import '../models/target.dart';
import 'api_key_provider.dart';

/// What Shodan already knows about a host.
///
/// This is passive: the data comes from Shodan's own historical scans, and no
/// packet is ever sent from the device to the target.
class ShodanHost {
  const ShodanHost({
    required this.ip,
    this.ports = const [],
    this.hostnames = const [],
    this.organisation = '',
    this.operatingSystem = '',
    this.services = const [],
    this.vulnerabilities = const [],
    this.lastUpdate,
  });

  final String ip;
  final List<int> ports;
  final List<String> hostnames;
  final String organisation;
  final String operatingSystem;
  final List<ShodanService> services;

  /// CVE identifiers Shodan associates with the observed service banners.
  ///
  /// These are inferences from version strings, not confirmed exploitable
  /// findings, and must be presented as leads to verify.
  final List<String> vulnerabilities;

  final DateTime? lastUpdate;
}

/// One service banner observed on a host.
class ShodanService {
  const ShodanService({
    required this.port,
    this.transport = '',
    this.product = '',
    this.version = '',
  });

  final int port;
  final String transport;
  final String product;
  final String version;

  /// A compact `443/tcp nginx 1.24.0` style label for list rows.
  String get label {
    final parts = <String>[
      transport.isEmpty ? '$port' : '$port/$transport',
      if (product.isNotEmpty) product,
      if (version.isNotEmpty) version,
    ];
    return parts.join(' ');
  }
}

/// Queries the Shodan host API.
class ShodanHostService {
  ShodanHostService({
    required ApiKeyProvider keys,
    http.Client? client,
    this.baseUrl = 'https://api.shodan.io',
    this.timeout = const Duration(seconds: 25),
  })  : _keys = keys,
        _client = client ?? http.Client();

  final ApiKeyProvider _keys;
  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'Shodan';

  /// Fetches what Shodan holds for [target], which must be an IP address.
  Future<SourceResult<ShodanHost>> host(Target target) async {
    if (!target.isIp) {
      return const SourceEmpty(sourceName, 'Only IP addresses are supported');
    }

    final key = await _keys.keyFor(ApiKeySource.shodan);
    if (key == null || key.isEmpty) {
      return const SourceFailure(
        sourceName,
        'No Shodan API key configured',
        needsApiKey: true,
      );
    }

    final uri = Uri.parse('$baseUrl/shodan/host/${target.value}')
        .replace(queryParameters: {'key': key});

    try {
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode == 404) {
        return const SourceEmpty(sourceName, 'No information for this host');
      }
      if (response.statusCode == 401) {
        return const SourceFailure(
          sourceName,
          'Shodan rejected the API key',
          needsApiKey: true,
        );
      }
      if (response.statusCode == 403) {
        return const SourceFailure(
          sourceName,
          'Shodan plan does not permit host lookups',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'Shodan returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }

      return SourceSuccess(sourceName, _parse(target.value, decoded));
    } catch (error) {
      return SourceFailure(sourceName, 'Shodan lookup failed: $error');
    }
  }

  static ShodanHost _parse(String ip, Map<String, dynamic> json) {
    final ports = <int>[];
    final rawPorts = json['ports'];
    if (rawPorts is List) {
      for (final port in rawPorts) {
        if (port is int) ports.add(port);
      }
    }
    ports.sort();

    final hostnames = <String>[];
    final rawHostnames = json['hostnames'];
    if (rawHostnames is List) {
      for (final hostname in rawHostnames) {
        if (hostname is String) hostnames.add(hostname.toLowerCase());
      }
    }

    final vulnerabilities = <String>[];
    final rawVulns = json['vulns'];
    if (rawVulns is List) {
      for (final vuln in rawVulns) {
        if (vuln is String) vulnerabilities.add(vuln);
      }
    } else if (rawVulns is Map<String, dynamic>) {
      vulnerabilities.addAll(rawVulns.keys);
    }
    vulnerabilities.sort();

    final services = <ShodanService>[];
    final banners = json['data'];
    if (banners is List) {
      for (final banner in banners) {
        if (banner is! Map<String, dynamic>) continue;
        final port = banner['port'];
        if (port is! int) continue;
        services.add(
          ShodanService(
            port: port,
            transport: (banner['transport'] as String?) ?? '',
            product: (banner['product'] as String?) ?? '',
            version: (banner['version'] as String?) ?? '',
          ),
        );
      }
    }
    services.sort((a, b) => a.port.compareTo(b.port));

    return ShodanHost(
      ip: (json['ip_str'] as String?) ?? ip,
      ports: ports,
      hostnames: hostnames,
      organisation: (json['org'] as String?) ?? '',
      operatingSystem: (json['os'] as String?) ?? '',
      services: services,
      vulnerabilities: vulnerabilities,
      lastUpdate: DateTime.tryParse((json['last_update'] as String?) ?? ''),
    );
  }

  void close() => _client.close();
}
