import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import 'data/services/secure_key_store.dart';
import 'ui/core/theme.dart';
import 'ui/features/brand/view_models/brand_view_model.dart';
import 'ui/features/due_diligence/view_models/due_diligence_view_model.dart';
import 'ui/features/home/views/home_shell.dart';
import 'ui/features/recon/view_models/recon_view_model.dart';
import 'ui/features/settings/view_models/settings_view_model.dart';
import 'ui/features/sources/view_models/sources_view_model.dart';
import 'ui/features/threat_intel/view_models/threat_intel_view_model.dart';

void main() {
  runApp(const OsintApp());
}

/// Wires the object graph and installs it above the UI.
///
/// Composition happens once, here, rather than inside widgets: services and
/// repositories are stateless, so a single shared HTTP client can serve every
/// feature and keep connections warm between scans.
class OsintApp extends StatelessWidget {
  const OsintApp({super.key});

  @override
  Widget build(BuildContext context) {
    final client = http.Client();
    final keyStore = SecureKeyStore();

    final dns = DnsOverHttpsService(client: client);
    final crtSh = CrtShService(client: client);
    final registry = IanaRegistryService(client: client);
    final shodan = ShodanHostService(keys: keyStore, client: client);
    final virusTotal = VirusTotalService(keys: keyStore, client: client);
    final abuseIpdb = AbuseIpdbService(keys: keyStore, client: client);
    final rdap = RdapService(client: client, bootstrapRegistry: registry);
    final otx = OtxService(client: client);
    final hackerTarget = HackerTargetService(client: client);
    final wayback = WaybackService(client: client);
    final feedService = ThreatFeedService(client: client);
    final blocklists = BlocklistRepository(feedService: feedService);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ReconViewModel(
            repository: ReconRepository(
              dns: dns,
              crtSh: crtSh,
              shodan: shodan,
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
            namespaceRepository: TldSweepRepository(
              dns: dns,
              registry: registry,
            ),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => DueDiligenceViewModel(
            repository: DueDiligenceRepository(
              rdap: rdap,
              dns: dns,
              crtSh: crtSh,
            ),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsViewModel(keyStore: keyStore),
        ),
        ChangeNotifierProvider(
          create: (_) => SourcesViewModel(
            repository: CatalogRepository(registry: registry),
          ),
        ),
      ],
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
