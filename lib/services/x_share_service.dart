import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'social_links.dart';

/// User-initiated posts to X — opens X compose (OAuth posting is server-side for daily batch).
class XShareService {
  static const int maxTweetLength = 280;

  static String truncateForTweet(String text, {int max = maxTweetLength}) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max - 1).trimRight()}…';
  }

  static String formatAnalysisPost({
    required String coin,
    required String report,
  }) {
    final sym = coin.trim().toUpperCase();
    final bias = _extractBias(report);
    final conviction = _extractConviction(report);
    final summary = _extractSummary(report);

    final lines = <String>[
      '🔮 On-Chain Oracle AI — $sym Analysis',
      if (bias.isNotEmpty) 'Bias: $bias${conviction.isNotEmpty ? ' ($conviction)' : ''}',
      if (summary.isNotEmpty) summary,
      '',
      '#OnChainOracle #Crypto #$sym',
      kXHandle,
    ];
    return truncateForTweet(lines.join('\n'));
  }

  static String formatWarRoomPost({
    required double bankrollUsd,
    required double winRatePct,
    required double avgRiskReward,
    required double aiAlphaUsd,
    required int closedCount,
  }) {
    String money(double v) {
      final sign = v >= 0 ? '+' : '-';
      final abs = v.abs();
      if (abs >= 1000000) return '$sign\$${(abs / 1000000).toStringAsFixed(2)}M';
      if (abs >= 1000) return '$sign\$${(abs / 1000).toStringAsFixed(1)}k';
      return '$sign\$${abs.toStringAsFixed(0)}';
    }

    String bank(double v) {
      final abs = v.abs();
      if (abs >= 1000000) return '\$1M';
      if (abs >= 1000) return '\$${(abs / 1000).toStringAsFixed(abs >= 10000 ? 0 : 1)}k';
      return '\$${abs.toStringAsFixed(0)}';
    }

    final wr = closedCount == 0 ? '—' : '${winRatePct.toStringAsFixed(0)}%';
    final rr = closedCount == 0 ? '—' : avgRiskReward.toStringAsFixed(2);
    final lines = <String>[
      '⚔️ On-Chain Oracle AI — War Room',
      'Bankroll ${bank(bankrollUsd)} · $closedCount closed',
      'Win rate $wr · Avg R $rr',
      'AI Alpha ${money(aiAlphaUsd)}',
      '',
      '#OnChainOracle #Crypto #AIAlpha',
      kXHandle,
    ];
    return truncateForTweet(lines.join('\n'));
  }

  static String formatNewsPost({
    required String headline,
    String? url,
  }) {
    final lines = <String>[
      '📰 $headline',
      '',
      '#OnChainOracle #Crypto #Bitcoin',
      if (url != null && url.trim().isNotEmpty) url.trim(),
    ];
    return truncateForTweet(lines.join('\n'));
  }

  static String _extractBias(String report) {
    final match = RegExp(
      r'Overall Bias\s*:?\s*([^\n(]+)',
      caseSensitive: false,
    ).firstMatch(report);
    return match?.group(1)?.trim() ?? '';
  }

  static String _extractConviction(String report) {
    final match = RegExp(
      r'Confidence\s*:?\s*(\d{1,3})\s*%',
      caseSensitive: false,
    ).firstMatch(report);
    return match != null ? '${match.group(1)}% conviction' : '';
  }

  static String _extractSummary(String report) {
    final match = RegExp(
      r'Confluence Summary\s*:?\s*(.+?)(?:\n\*\*|\n\n|\Z)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(report);
    final raw = match?.group(1)?.trim() ?? '';
    if (raw.isEmpty) return '';
    return truncateForTweet(raw, max: 140);
  }

  /// Opens X/Twitter compose with pre-filled text (external app or browser).
  static Future<bool> pushToX(BuildContext context, String text) async {
    final tweet = truncateForTweet(text);
    if (tweet.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nothing to post — add text first.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final encoded = Uri.encodeComponent(tweet);
    final urls = [
      'https://x.com/intent/tweet?text=$encoded',
      'https://twitter.com/intent/tweet?text=$encoded',
    ];

    for (final raw in urls) {
      final uri = Uri.parse(raw);
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      } catch (e) {
        debugPrint('[XShare] launch failed $raw: $e');
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open X. Install the X app or try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return false;
  }

  /// Compose sheet — edit text then push to X.
  static Future<void> showComposeSheet(
    BuildContext context, {
    required String initialText,
    String title = 'Push to X',
  }) async {
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _XComposeSheet(
        initialText: initialText,
        title: title,
        parentContext: context,
      ),
    );
  }
}

class _XComposeSheet extends StatefulWidget {
  final String initialText;
  final String title;
  final BuildContext parentContext;

  const _XComposeSheet({
    required this.initialText,
    required this.title,
    required this.parentContext,
  });

  @override
  State<_XComposeSheet> createState() => _XComposeSheetState();
}

class _XComposeSheetState extends State<_XComposeSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            widget.title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Opens X compose — automated daily posts run from the server.',
            style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.35),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            maxLines: 6,
            maxLength: XShareService.maxTweetLength,
            style: const TextStyle(fontSize: 14, height: 1.45),
            decoration: InputDecoration(
              hintText: 'Edit your post…',
              filled: true,
              fillColor: const Color(0xFF0A0A0A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[800]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF00BFFF), width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final text = _controller.text.trim();
              Navigator.of(context).pop();
              await XShareService.pushToX(widget.parentContext, text);
            },
            icon: const Icon(Icons.north_east, size: 18),
            label: const Text('Push to X'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00BFFF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}
