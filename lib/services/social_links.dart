import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Official On-Chain Oracle social URLs (single source of truth).
const String kXProfileUrl = 'https://x.com/OnChainOracleA';
const String kXProfileTwitterFallbackUrl = 'https://twitter.com/OnChainOracleA';
const String kYouTubePlaylistUrl = 'https://www.youtube.com/playlist?list=PLR5HNGs7bPmo';
const String kYouTubePlaylistShortUrl = 'https://youtube.com/playlist?list=PLR5HNGs7bPmo';
const String kYouTubePlaylistAppUrl = 'vnd.youtube://playlist?list=PLR5HNGs7bPmo';

const String kXHandle = '@OnChainOracleA';

const String kPrivacyPolicyUrl = 'https://onchainoracleai.com/privacy';
const String kSupportEmail = 'support@onchainoracleai.com';
const String kSupportMailtoUrl = 'mailto:support@onchainoracleai.com';

/// Opens [urls] in order — external browser / native app (YouTube, X, etc.).
Future<bool> openSocialUrls(
  BuildContext context, {
  required List<String> urls,
  required String label,
}) async {
  for (final raw in urls) {
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return true;
    } catch (e) {
      debugPrint('[SocialLinks] launch failed for $raw: $e');
    }
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open $label'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return false;
}

Future<bool> openXProfile(BuildContext context) {
  return openSocialUrls(
    context,
    urls: [kXProfileUrl, kXProfileTwitterFallbackUrl],
    label: 'X',
  );
}

Future<bool> openPrivacyPolicy(BuildContext context) {
  return openSocialUrls(
    context,
    urls: [kPrivacyPolicyUrl],
    label: 'Privacy Policy',
  );
}

Future<bool> openSupportEmail(BuildContext context) {
  return openSocialUrls(
    context,
    urls: [kSupportMailtoUrl],
    label: 'Support Email',
  );
}

Future<bool> openYouTubePlaylist(BuildContext context) {
  return openSocialUrls(
    context,
    urls: [
      kYouTubePlaylistAppUrl,
      kYouTubePlaylistUrl,
      kYouTubePlaylistShortUrl,
    ],
    label: 'YouTube',
  );
}
