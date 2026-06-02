// ─── Oracle Trader AI chat entry points — icon update ────────────────────────
//
// All AI chat FABs and restore buttons now use Icons.auto_awesome (modern AI
// sparkle) instead of chat_bubble icons. Button color, size, position, and
// onPressed behavior are unchanged — only the glyph was swapped.
//
import 'package:flutter/material.dart';

/// Shared sparkle icon for every Oracle AI Chat entry point.
const IconData kOracleAiChatIcon = Icons.auto_awesome;

/// Small blue FAB on report screens (Analysis, Review, Trade Setup results).
class CompactChatFab extends StatelessWidget {
  final Object heroTag;
  final VoidCallback onPressed;

  const CompactChatFab({
    super.key,
    required this.heroTag,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: heroTag,
      backgroundColor: const Color(0xFF00BFFF),
      foregroundColor: Colors.black,
      tooltip: 'Oracle AI Chat',
      onPressed: onPressed,
      child: const Icon(kOracleAiChatIcon, size: 20),
    );
  }
}
