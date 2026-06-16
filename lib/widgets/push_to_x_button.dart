import 'package:flutter/material.dart';

import '../services/x_share_service.dart';

/// One-tap entry to the X compose sheet.
class PushToXButton extends StatelessWidget {
  final String initialText;
  final String sheetTitle;
  final bool iconOnly;
  final String? tooltip;

  const PushToXButton({
    super.key,
    required this.initialText,
    this.sheetTitle = 'Push to X',
    this.iconOnly = false,
    this.tooltip = 'Push to X',
  });

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      return IconButton(
        tooltip: tooltip,
        icon: const Icon(Icons.north_east, size: 20),
        onPressed: () => XShareService.showComposeSheet(
          context,
          initialText: initialText,
          title: sheetTitle,
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: () => XShareService.showComposeSheet(
        context,
        initialText: initialText,
        title: sheetTitle,
      ),
      icon: const Icon(Icons.north_east, size: 18),
      label: const Text('Push to X'),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF00BFFF),
        side: BorderSide(color: const Color(0xFF00BFFF).withValues(alpha: 0.45)),
      ),
    );
  }
}
