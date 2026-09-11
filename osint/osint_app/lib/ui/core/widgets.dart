import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:osint_core/osint_core.dart';

/// A titled card used for every block of findings, so the four feature
/// screens read as one tool rather than four.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// A label/value row, with the value selectable so findings can be copied
/// straight into a ticket or a report.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A monospace row for a technical record, with a long-press to copy.
class RecordRow extends StatelessWidget {
  const RecordRow({required this.text, this.leading, super.key});

  final String text;
  final String? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied')),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null)
              Container(
                width: 52,
                margin: const EdgeInsets.only(right: 8, top: 1),
                child: Text(
                  leading!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders per-source status for a scan.
///
/// This is the component that keeps the tool honest: it shows which sources
/// answered, which had nothing, and which failed, so a thin result is never
/// mistaken for a clean one.
class SourceNotesList extends StatelessWidget {
  const SourceNotesList({required this.notes, this.onOpenSettings, super.key});

  final List<SourceNote> notes;

  /// Called when a note reports a missing credential.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (notes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  note.ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 16,
                  color: note.ok
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: note.source,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (note.message.isNotEmpty)
                          TextSpan(
                            text: ' — ${note.message}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (note.needsApiKey && onOpenSettings != null)
                  TextButton(
                    onPressed: onOpenSettings,
                    child: const Text('Add key'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Placeholder shown before a scan has been run, or when it found nothing.
class EmptyState extends StatelessWidget {
  const EmptyState({required this.icon, required this.message, super.key});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The target entry field shared by every feature screen.
class TargetField extends StatelessWidget {
  const TargetField({
    required this.controller,
    required this.onSubmit,
    required this.isBusy,
    this.hint = 'example.com',
    this.label = 'Target',
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final bool isBusy;
  final String hint;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !isBusy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => onSubmit(),
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: isBusy ? null : onSubmit,
            child: isBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Scan'),
          ),
        ),
      ],
    );
  }
}
