import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../view_models/settings_view_model.dart';

/// API key management.
///
/// Keys are write-only from the UI's point of view: once stored they are never
/// read back into a text field, so a shoulder-surfer or a screenshot cannot
/// recover a credential that is already saved.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Read stored state once the first frame is scheduled, so the view model
    // is not mutated during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SettingsViewModel>().load();
    });
  }

  Future<void> _edit(ApiKeySource source) async {
    final controller = TextEditingController();
    final viewModel = context.read<SettingsViewModel>();

    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.displayName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Get a key from:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SelectableText(
              source.signupUrl,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (key == null) return;
    await viewModel.save(source, key);
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SettingsViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('API keys')),
      body: viewModel.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keyless sources',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'DNS, Certificate Transparency (crt.sh) and RDAP '
                          'registration data need no key and are always '
                          'available. Recon, brand protection and due '
                          'diligence work without configuring anything below.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final source in ApiKeySource.values)
                  Card(
                    child: ListTile(
                      title: Text(source.displayName),
                      subtitle: Text(
                        viewModel.configured[source] == true
                            ? 'Key stored'
                            : 'Not configured',
                      ),
                      leading: Icon(
                        viewModel.configured[source] == true
                            ? Icons.key
                            : Icons.key_off_outlined,
                        color: viewModel.configured[source] == true
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (viewModel.configured[source] == true)
                            IconButton(
                              tooltip: 'Remove key',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => viewModel.clear(source),
                            ),
                          IconButton(
                            tooltip: 'Set key',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(source),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Keys are stored in the Android keystore and are sent only '
                    'to the source they belong to.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
    );
  }
}
