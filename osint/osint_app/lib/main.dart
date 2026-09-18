import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'data/services/image_indicator_scanner.dart';
import 'data/services/secure_key_store.dart';
import 'ui/core/theme.dart';
import 'ui/features/brand/view_models/brand_view_model.dart';
import 'ui/features/due_diligence/view_models/due_diligence_view_model.dart';
import 'ui/features/home/views/home_shell.dart';
import 'ui/features/image_scan/view_models/image_scan_view_model.dart';
import 'ui/features/recon/view_models/recon_view_model.dart';
import 'ui/features/settings/view_models/settings_view_model.dart';
import 'ui/features/sources/view_models/sources_view_model.dart';
import 'ui/features/threat_intel/view_models/threat_intel_view_model.dart';

void main() {
  runApp(const OsintApp());
}

/// Wires the object graph and installs it above the UI.
///
/// Stateful rather than stateless on purpose. Flutter calls build() again on
/// every rebuild, so constructing the graph there would allocate a fresh HTTP
/// client and a fresh set of services each time, leaking sockets and native
/// ML Kit detectors for the life of the process. The graph is built once in
/// initState and released in dispose.
class OsintApp extends StatefulWidget {
  const OsintApp({super.key});

  @override
  State<OsintApp> createState() => _OsintAppState();
}

class _OsintAppState extends State<OsintApp> {
  late final http.Client _client;
  late final MlKitImageScanner _imageScanner;
  late final List<SingleChildWidget> _providers;

  @override
  void initState() {
    super.initState();

    final client = http.Client();
    _client = client;
    final keyStore = SecureKeyStore();

    final dns = DnsOverHttpsService(client: client);
    final crtSh = CrtShService(client: client);
    final registry = IanaRegistryService(client: client);
    final shodan = ShodanHostService(keys: keyStore, client: client);
    final virusTotal = VirusTotalService(keys: keyStore, client: client);
    final abuseIpdb = AbuseIpdbService(keys: keyStore, client: client);
    final rdap = RdapService(client: client, bootstrapRegistry: registry);
    final otx = OtxService(client: client);
    final asnLookup = AsnLookupService(dns: dns);
    final internetDb = InternetDbService(client: client);
    final mailSecurity = MailSecurityService(dns: dns);
    final hackerTarget = HackerTargetService(client: client);
    final wayback = WaybackService(client: client);
    final feedService = ThreatFeedService(client: client);
    final blocklists = BlocklistRepository(feedService: feedService);

    final imageScanner = MlKitImageScanner();
    _imageScanner = imageScanner;

    _providers = [
      ChangeNotifierProvider(
        create: (_) => ReconViewModel(
          repository: ReconRepository(
            dns: dns,
            crtSh: crtSh,
            shodan: shodan,
            asnLookup: asnLookup,
            internetDb: internetDb,
            hackerTarget: hackerTarget,
            otx: otx,
            wayback: wayback,
          ),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => ThreatIntelViewModel(
          repository: ThreatIntelRepository(
            virusTotal: virusTotal,
            abuseIpdb: abuseIpdb,
            otx: otx,
            blocklists: blocklists,
          ),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => BrandViewModel(
          repository: BrandRepository(dns: dns),
          namespaceRepository: TldSweepRepository(dns: dns, registry: registry),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => DueDiligenceViewModel(
          repository: DueDiligenceRepository(
            rdap: rdap,
            dns: dns,
            crtSh: crtSh,
            mailSecurity: mailSecurity,
          ),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => SettingsViewModel(keyStore: keyStore),
      ),
      ChangeNotifierProvider(
        create: (_) =>
            ImageScanViewModel(scanner: imageScanner, registry: registry),
      ),
      ChangeNotifierProvider(
        create: (_) =>
            SourcesViewModel(repository: CatalogRepository(registry: registry)),
      ),
    ];
  }

  @override
  void dispose() {
    // Native ML Kit detectors and the shared socket pool both outlive the
    // widget tree unless released explicitly.
    _imageScanner.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: _providers,
      child: MaterialApp(
        title: 'OSINT',
        debugShowCheckedModeBanner: false,
        theme: OsintTheme.light(),
        darkTheme: OsintTheme.dark(),
        home: const HomeShell(),
      ),
    );
  }
}
