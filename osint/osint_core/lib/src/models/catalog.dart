/// The kind of thing a catalogue section enumerates.
enum CatalogKind {
  /// Servers that can be queried directly for data, e.g. RDAP registry
  /// endpoints and Certificate Transparency logs.
  queryableEndpoint,

  /// Namespaces a brand can be registered in, used as sweep targets rather
  /// than queried for data.
  namespace,

  /// Bulk threat feeds fetched and searched locally.
  feed,

  /// A hand-written API integration.
  api,
}

/// One enumerated group of sources.
class CatalogSection {
  const CatalogSection({
    required this.name,
    required this.kind,
    required this.count,
    required this.origin,
    this.detail = '',
    this.stale = false,
  });

  final String name;
  final CatalogKind kind;

  /// How many sources this section contributes.
  final int count;

  /// Where the list itself came from, so a count can always be traced back to
  /// the authority that published it.
  final String origin;

  final String detail;

  /// True when the count came from the bundled fallback rather than a live
  /// fetch, so the UI never presents cached numbers as current.
  final bool stale;
}

/// The full enumerated source catalogue.
///
/// Deliberately reports two different totals. Conflating them would inflate
/// the headline number: a public suffix is somewhere a domain can exist, not
/// a server that answers questions.
class SourceCatalog {
  const SourceCatalog({required this.sections, required this.fetchedAt});

  final List<CatalogSection> sections;
  final DateTime fetchedAt;

  /// Sources that can actually be queried or searched for data: registry
  /// servers, CT logs, threat feeds and API integrations.
  int get queryableCount => sections
      .where((section) => section.kind != CatalogKind.namespace)
      .fold(0, (total, section) => total + section.count);

  /// Namespaces a brand sweep can cover.
  int get namespaceCount => sections
      .where((section) => section.kind == CatalogKind.namespace)
      .fold(0, (total, section) => total + section.count);

  /// Every catalogued entry, of either kind.
  int get totalCount =>
      sections.fold(0, (total, section) => total + section.count);

  /// True when any section fell back to bundled data.
  bool get hasStaleSections => sections.any((section) => section.stale);

  /// Sections of one kind, for grouped display.
  List<CatalogSection> ofKind(CatalogKind kind) =>
      sections.where((section) => section.kind == kind).toList();
}
