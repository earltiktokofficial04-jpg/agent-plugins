import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_result.dart';

/// A URL the Internet Archive has captured.
class ArchivedUrl {
  const ArchivedUrl({
    required this.url,
    required this.timestamp,
    this.statusCode = '',
    this.mimeType = '',
  });

  final String url;
  final DateTime? timestamp;
  final String statusCode;
  final String mimeType;
}

/// Queries the Internet Archive's CDX index.
///
/// Archived URLs expose paths that are no longer linked or served — old admin
/// panels, staging hosts, exposed config files — which neither DNS nor
/// Certificate Transparency can reveal.
class WaybackService {
  WaybackService({
    http.Client? client,
    this.baseUrl = 'https://web.archive.org/cdx/search/cdx',
    this.timeout = const Duration(seconds: 40),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const String sourceName = 'Wayback Machine';

  /// Captured URLs under [domain], newest first.
  ///
  /// [limit] caps the response: a busy domain has millions of captures, and
  /// the index returns them all unless told otherwise.
  Future<SourceResult<List<ArchivedUrl>>> urlsFor(
    String domain, {
    int limit = 200,
  }) async {
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'url': '*.$domain/*',
      'output': 'json',
      'fl': 'original,timestamp,statuscode,mimetype',
      'collapse': 'urlkey',
      'limit': '-$limit',
    });

    try {
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode != 200) {
        return SourceFailure(sourceName, 'HTTP ${response.statusCode}');
      }
      if (response.body.trim().isEmpty) {
        return const SourceEmpty(sourceName, 'No captures');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) {
        return const SourceEmpty(sourceName, 'No captures');
      }

      // The first row is a header naming the requested fields.
      final rows = decoded.skip(1);
      final urls = <ArchivedUrl>[];
      for (final row in rows) {
        if (row is! List || row.isEmpty) continue;
        urls.add(
          ArchivedUrl(
            url: '${row[0]}',
            timestamp:
                row.length > 1 ? _parseTimestamp('${row[1]}') : null,
            statusCode: row.length > 2 ? '${row[2]}' : '',
            mimeType: row.length > 3 ? '${row[3]}' : '',
          ),
        );
      }

      if (urls.isEmpty) {
        return const SourceEmpty(sourceName, 'No captures');
      }
      return SourceSuccess(sourceName, urls);
    } catch (error) {
      return SourceFailure(sourceName, 'Wayback query failed: $error');
    }
  }

  /// Parses the CDX `yyyyMMddHHmmss` timestamp format.
  static DateTime? _parseTimestamp(String value) {
    if (value.length < 8) return null;
    final iso = '${value.substring(0, 4)}-${value.substring(4, 6)}-'
        '${value.substring(6, 8)}'
        '${value.length >= 14 ? 'T${value.substring(8, 10)}:'
            '${value.substring(10, 12)}:${value.substring(12, 14)}Z' : ''}';
    return DateTime.tryParse(iso);
  }

  void close() => _client.close();
}
