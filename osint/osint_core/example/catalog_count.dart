// Prints the live source catalogue, so the headline numbers can be checked
// against the registries that publish them rather than taken on trust.
//
//   dart run example/catalog_count.dart
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:osint_core/osint_core.dart';

Future<void> main() async {
  final inner = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  final client = IOClient(inner);

  final repository = CatalogRepository(
    registry: IanaRegistryService(client: client),
  );

  final catalog = await repository.load(
    onProgress: (stage) => stdout.writeln('… $stage'),
  );

  stdout.writeln('');
  for (final section in catalog.sections) {
    stdout.writeln(
      '${section.count.toString().padLeft(7)}  ${section.name.padRight(34)}'
      '${section.stale ? 'STALE  ' : '       '}${section.origin}',
    );
  }

  stdout.writeln('');
  stdout.writeln('queryable sources : ${catalog.queryableCount}');
  stdout.writeln('namespaces        : ${catalog.namespaceCount}');
  stdout.writeln('catalogue total   : ${catalog.totalCount}');

  // Also load every threat feed and report the corpus size.
  final feedService = ThreatFeedService(client: client);
  final blocklists = BlocklistRepository(feedService: feedService);
  final report = await blocklists.check(Target.parse('185.220.101.1'));

  stdout.writeln('');
  stdout.writeln('feeds loaded      : ${report.feedsChecked} of '
      '${blocklists.feeds.length}');
  stdout.writeln('feed entries      : ${report.entriesSearched}');
  for (final note in report.notes.where((note) => !note.ok)) {
    stdout.writeln('  failed: ${note.source} — ${note.message}');
  }
  stdout.writeln('test IP hits      : ${report.hits.length}');
  for (final hit in report.hits) {
    stdout.writeln('  ${hit.feed.name} → ${hit.matchedBlock} '
        '(${hit.feed.severity.name})');
  }

  client.close();
}
