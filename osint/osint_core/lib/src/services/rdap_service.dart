import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/registration.dart';
import '../models/source_result.dart';

/// Fetches domain registration data over RDAP.
///
/// Uses the rdap.org bootstrap service, which redirects to the authoritative
/// registry server for the TLD, so the app does not have to carry its own copy
/// of the IANA bootstrap table.
class RdapService {
  RdapService({
    http.Client? client,
    this.baseUrl = 'https://rdap.org',
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'RDAP';

  /// Looks up the registration record for [domain].
  Future<SourceResult<DomainRegistration>> domain(String domain) async {
    final uri = Uri.parse('$baseUrl/domain/$domain');

    try {
      final response = await _client
          .get(uri, headers: {'Accept': 'application/rdap+json'})
          .timeout(timeout);

      if (response.statusCode == 404) {
        return const SourceEmpty(
          sourceName,
          'No registration record — domain appears unregistered',
        );
      }
      if (response.statusCode != 200) {
        return SourceFailure(
          sourceName,
          'RDAP returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const SourceFailure(sourceName, 'Unexpected RDAP payload');
      }

      return SourceSuccess(sourceName, _parse(domain, decoded));
    } catch (error) {
      return SourceFailure(sourceName, 'RDAP lookup failed: $error');
    }
  }

  static DomainRegistration _parse(
    String domain,
    Map<String, dynamic> json,
  ) {
    // Events carry the registration lifecycle dates, keyed by action name.
    DateTime? eventDate(String action) {
      final events = json['events'];
      if (events is! List) return null;
      for (final event in events) {
        if (event is! Map<String, dynamic>) continue;
        if (event['eventAction'] == action) {
          final date = event['eventDate'];
          if (date is String) return DateTime.tryParse(date);
        }
      }
      return null;
    }

    final nameservers = <String>[];
    final rawNameservers = json['nameservers'];
    if (rawNameservers is List) {
      for (final nameserver in rawNameservers) {
        if (nameserver is! Map<String, dynamic>) continue;
        final name = nameserver['ldhName'];
        if (name is String && name.isNotEmpty) {
          nameservers.add(name.toLowerCase());
        }
      }
    }

    final statuses = <String>[];
    final rawStatuses = json['status'];
    if (rawStatuses is List) {
      for (final status in rawStatuses) {
        if (status is String) statuses.add(status);
      }
    }

    final secureDns = json['secureDNS'];
    final dnssecSigned = secureDns is Map<String, dynamic> &&
        secureDns['delegationSigned'] == true;

    return DomainRegistration(
      domain: (json['ldhName'] as String?)?.toLowerCase() ?? domain,
      registrar: _registrarName(json),
      registered: eventDate('registration'),
      expires: eventDate('expiration'),
      lastChanged: eventDate('last changed'),
      statuses: statuses,
      nameservers: nameservers,
      dnssecSigned: dnssecSigned,
    );
  }

  /// Pulls the registrar's name out of the jCard structure RDAP embeds.
  ///
  /// The vCard array format is awkward: entity.vcardArray is
  /// `['vcard', [[property, params, type, value], ...]]`, so the name has to
  /// be located by scanning for the `fn` property.
  static String _registrarName(Map<String, dynamic> json) {
    final entities = json['entities'];
    if (entities is! List) return '';

    for (final entity in entities) {
      if (entity is! Map<String, dynamic>) continue;
      final roles = entity['roles'];
      if (roles is! List || !roles.contains('registrar')) continue;

      final vcardArray = entity['vcardArray'];
      if (vcardArray is! List || vcardArray.length < 2) continue;
      final properties = vcardArray[1];
      if (properties is! List) continue;

      for (final property in properties) {
        if (property is! List || property.length < 4) continue;
        if (property[0] == 'fn' && property[3] is String) {
          return property[3] as String;
        }
      }
    }
    return '';
  }

  void close() => _client.close();
}
