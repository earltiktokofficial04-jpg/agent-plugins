import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/registration.dart';
import '../models/source_result.dart';
import 'iana_registry_service.dart';

/// Fetches domain registration data over RDAP.
///
/// When an [IanaRegistryService] is supplied, the IANA bootstrap is consulted
/// and the query goes straight to the TLD's own registry server — the
/// authoritative source, and the reason the bootstrap is worth enumerating at
/// all. Without it, or for a TLD that publishes no RDAP server, the query
/// falls back to the rdap.org redirector.
class RdapService {
  RdapService({
    http.Client? client,
    this.baseUrl = 'https://rdap.org',
    this.timeout = const Duration(seconds: 20),
    IanaRegistryService? bootstrapRegistry,
  })  : _client = client ?? http.Client(),
        _bootstrapRegistry = bootstrapRegistry;

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;
  final IanaRegistryService? _bootstrapRegistry;

  RdapBootstrap? _bootstrap;
  bool _bootstrapAttempted = false;

  static const String sourceName = 'RDAP';

  /// Resolves the authoritative RDAP base URL for [domain], or null.
  ///
  /// The bootstrap is fetched at most once per service instance, and a failed
  /// fetch is not retried: falling back to the redirector for the rest of the
  /// session beats re-downloading a 300KB table on every lookup.
  Future<String?> _authoritativeServerFor(String domain) async {
    final registry = _bootstrapRegistry;
    if (registry == null) return null;

    if (!_bootstrapAttempted) {
      _bootstrapAttempted = true;
      _bootstrap = (await registry.rdapBootstrap()).valueOrNull;
    }
    return _bootstrap?.serverFor(domain);
  }

  /// Joins an RDAP base URL to a domain query path.
  ///
  /// Bootstrap entries usually carry a trailing slash and sometimes a path
  /// segment, so the separator has to be normalised rather than assumed.
  static Uri _domainUri(String base, String domain) {
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return Uri.parse('$trimmed/domain/$domain');
  }

  /// The TLD of [domain], or an empty string.
  static String _tldOf(String domain) {
    final parts = domain.toLowerCase().split('.');
    return parts.length < 2 ? '' : parts.last;
  }

  /// Looks up the registration record for [domain].
  Future<SourceResult<DomainRegistration>> domain(String domain) async {
    final authoritative = await _authoritativeServerFor(domain);
    final server = authoritative ?? baseUrl;
    final uri = _domainUri(server, domain);

    // Whether the TLD publishes RDAP at all decides what a 404 means.
    final coverageKnown = _bootstrap != null;
    final tldCovered = authoritative != null;

    try {
      final response = await _client
          .get(uri, headers: {'Accept': 'application/rdap+json'})
          .timeout(timeout);

      if (response.statusCode == 404) {
        // A 404 is ambiguous, and reading it wrongly is dangerous: many ccTLDs
        // (.my among them) publish no RDAP service at all, so a miss there says
        // nothing about whether the domain exists. Reporting a live company's
        // domain as unregistered would be a false conclusion in exactly the
        // assessment this module is built for.
        if (coverageKnown && !tldCovered) {
          return SourceEmpty(
            sourceName,
            'No RDAP service published for .${_tldOf(domain)} — registration '
            'cannot be checked this way',
          );
        }
        if (!coverageKnown) {
          return SourceEmpty(
            sourceName,
            'No record returned — the domain may be unregistered, or '
            '.${_tldOf(domain)} may publish no RDAP service',
          );
        }
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

      return SourceSuccess(sourceName, _parse(domain, decoded, server));
    } catch (error) {
      return SourceFailure(sourceName, 'RDAP lookup failed: $error');
    }
  }

  static DomainRegistration _parse(
    String domain,
    Map<String, dynamic> json,
    String registryServer,
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
      registryServer: registryServer,
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
