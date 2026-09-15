import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_result.dart';
import '../models/target.dart';

/// What Shodan's free InternetDB knows about a host.
class InternetDbHost {
  const InternetDbHost({
    required this.ip,
    this.ports = const [],
    this.hostnames = const [],
    this.cpes = const [],
    this.vulnerabilities = const [],
    this.tags = const [],
  });

  final String ip;
  final List<int> ports;
  final List<String> hostnames;

  /// CPE identifiers for the software Shodan fingerprinted, e.g.
  /// `cpe:/a:openbsd:openssh:6.6.1p1`.
  final List<String> cpes;

  /// CVE identifiers Shodan associates with those fingerprints.
  ///
  /// Inferred from version banners, not confirmed exploitable — leads to
  /// verify, exactly as with the paid Shodan API.
  final List<String> vulnerabilities;

  /// Shodan's own labels, e.g. `cloud`, `honeypot`.
  final List<String> tags;

  bool get isEmpty =>
      ports.isEmpty && hostnames.isEmpty && cpes.isEmpty && tags.isEmpty;
}

/// Queries Shodan's InternetDB.
///
/// InternetDB is the free, keyless subset of Shodan's host data: open ports,
/// reverse hostnames, software fingerprints and associated CVEs, with no API
/// key and no credit cost. The paid host API returns more — banners, per-port
/// detail, scan timestamps — but for most triage this answers the question at
/// no cost, so it runs for every user rather than only those who have
/// configured a Shodan key.
class InternetDbService {
  InternetDbService({
    http.Client? client,
    this.baseUrl = 'https://internetdb.shodan.io',
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'Shodan InternetDB';

  /// Looks up [target], which must be an IP address.
  Future<SourceResult<InternetDbHost>> host(Target target) async {
    if (!target.isIp) {
      return const SourceEmpty(sourceName, 'Only IP addresses are supported');
    }

    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/${target.value}'))
          .timeout(timeout);

      // InternetDB answers 404 for an address it has never observed, which is
      // a finding rather than an error.
      if (response.statusCode == 404) {
        return const SourceEmpty(sourceName, 'No observations for this host');
      }
      if (response.statusCode == 429) {
        return const SourceFailure(
          sourceName,
          'Rate limited — InternetDB allows roughly one request per second',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(sourceName, 'HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected payload');
      }

      final parsed = _parse(target.value, decoded);
      if (parsed.isEmpty) {
        return const SourceEmpty(sourceName, 'Host known but nothing recorded');
      }
      return SourceSuccess(sourceName, parsed);
    } catch (error) {
      return SourceFailure(sourceName, 'InternetDB lookup failed: $error');
    }
  }

  static InternetDbHost _parse(String ip, Map<String, dynamic> json) {
    List<String> strings(String field) {
      final value = json[field];
      if (value is! List) return const [];
      return [
        for (final item in value)
          if (item is String && item.isNotEmpty) item,
      ];
    }

    final ports = <int>[];
    final rawPorts = json['ports'];
    if (rawPorts is List) {
      for (final port in rawPorts) {
        if (port is int) ports.add(port);
      }
    }
    ports.sort();

    final vulns = strings('vulns')..sort();
    final hostnames = [
      for (final hostname in strings('hostnames')) hostname.toLowerCase(),
    ]..sort();

    return InternetDbHost(
      ip: (json['ip'] as String?) ?? ip,
      ports: ports,
      hostnames: hostnames,
      cpes: strings('cpes'),
      vulnerabilities: vulns,
      tags: strings('tags'),
    );
  }

  void close() => _client.close();
}
