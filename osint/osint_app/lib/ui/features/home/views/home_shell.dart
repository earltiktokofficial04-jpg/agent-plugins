import 'package:flutter/material.dart';

import '../../brand/views/brand_screen.dart';
import '../../due_diligence/views/due_diligence_screen.dart';
import '../../recon/views/recon_screen.dart';
import '../../settings/views/settings_screen.dart';
import '../../sources/views/sources_screen.dart';
import '../../threat_intel/views/threat_intel_screen.dart';

/// The app shell: four feature tabs plus settings.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<String> _titles = [
    'Recon',
    'Threat intel',
    'Brand',
    'Due diligence',
  ];

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  void _openSources() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SourcesScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          IconButton(
            tooltip: 'Sources',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: _openSources,
          ),
          IconButton(
            tooltip: 'API keys',
            icon: const Icon(Icons.key_outlined),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const _ScopeDialog(),
            ),
          ),
        ],
      ),
      // IndexedStack keeps each tab's results and scroll position alive, so
      // switching tabs mid-investigation does not discard a finished scan.
      body: IndexedStack(
        index: _index,
        children: [
          ReconScreen(onOpenSettings: _openSettings),
          ThreatIntelScreen(onOpenSettings: _openSettings),
          const BrandScreen(),
          const DueDiligenceScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.travel_explore_outlined),
            selectedIcon: Icon(Icons.travel_explore),
            label: 'Recon',
          ),
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'Intel',
          ),
          NavigationDestination(
            icon: Icon(Icons.copy_all_outlined),
            selectedIcon: Icon(Icons.copy_all),
            label: 'Brand',
          ),
          NavigationDestination(
            icon: Icon(Icons.business_outlined),
            selectedIcon: Icon(Icons.business),
            label: 'Diligence',
          ),
        ],
      ),
    );
  }
}

/// States plainly what the tool does and does not do.
class _ScopeDialog extends StatelessWidget {
  const _ScopeDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('What this tool does'),
      content: const SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Every lookup is passive. Data comes from public DNS resolvers, '
              'Certificate Transparency logs, registry RDAP endpoints and '
              'third-party reputation databases.',
            ),
            SizedBox(height: 10),
            Text(
              'No traffic is ever sent to the domain or host under '
              'investigation, and the app contains no port scanning, probing '
              'or exploitation capability.',
            ),
            SizedBox(height: 10),
            Text(
              'Findings are leads, not conclusions. Certificate Transparency '
              'hosts may be long decommissioned, Shodan banners are '
              'historical, and CVE associations are inferred from version '
              'strings rather than confirmed.',
            ),
            SizedBox(height: 10),
            Text(
              'Aimed at infrastructure and organisations — your own estate, '
              'assets you are authorised to assess, brand impersonation, and '
              'counterparty checks.',
            ),
            SizedBox(height: 10),
            Text(
              'The Sources screen lists every registry and feed consulted, '
              'with each count traced to the body that publishes the list.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
