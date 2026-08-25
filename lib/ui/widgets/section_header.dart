import 'package:flutter/material.dart';

/// A small labeled row (icon + title, optional trailing action) used above
/// a section of content — e.g. "Popular items", "Categories", "Live map".
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.label, this.trailing});

  final IconData icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}
