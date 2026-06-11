import 'package:flutter/material.dart';

import '../services/social_links.dart';

const String kCommunityDiscordUrl = 'https://discord.gg/n36NAszBd';

/// Glowing social / community link cards for Profile.
class CommunityLinksSection extends StatelessWidget {
  const CommunityLinksSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CommunityLinkCard(
          title: 'X / Twitter',
          subtitle: '$kXHandle — live updates & alpha',
          accentColor: const Color(0xFF00BFFF),
          icon: const _XBrandIcon(),
          onTap: () => openXProfile(context),
        ),
        _CommunityLinkCard(
          title: 'Discord',
          subtitle: 'Join the Oracle trader community',
          accentColor: const Color(0xFF5865F2),
          icon: const _DiscordBrandIcon(),
          onTap: () => openSocialUrls(
            context,
            urls: [kCommunityDiscordUrl],
            label: 'Discord',
          ),
        ),
        _CommunityLinkCard(
          title: 'YouTube Playlist',
          subtitle: 'Watch Oracle walkthroughs & education',
          accentColor: const Color(0xFFFF1744),
          icon: const _YouTubeBrandIcon(),
          onTap: () => openYouTubePlaylist(context),
        ),
      ],
    );
  }
}

class _CommunityLinkCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color accentColor;
  final Widget icon;
  final VoidCallback onTap;

  const _CommunityLinkCard({
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accentColor.withValues(alpha: 0.14),
                  const Color(0xFF12141C),
                  const Color(0xFF0A0A0E),
                ],
              ),
              border: Border.all(color: accentColor.withValues(alpha: 0.32)),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.12),
                  blurRadius: 18,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.22),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Center(child: icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.open_in_new_rounded, size: 18, color: accentColor.withValues(alpha: 0.85)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _XBrandIcon extends StatelessWidget {
  const _XBrandIcon();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '𝕏',
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w900,
        color: Colors.white,
        height: 1,
      ),
    );
  }
}

class _DiscordBrandIcon extends StatelessWidget {
  const _DiscordBrandIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 18),
      painter: _DiscordIconPainter(),
    );
  }
}

class _DiscordIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE8EAFF)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.18, h * 0.22)
      ..cubicTo(w * 0.42, h * 0.08, w * 0.58, h * 0.08, w * 0.82, h * 0.22)
      ..lineTo(w * 0.92, h * 0.55)
      ..cubicTo(w * 0.78, h * 0.72, w * 0.66, h * 0.82, w * 0.5, h * 0.88)
      ..cubicTo(w * 0.34, h * 0.82, w * 0.22, h * 0.72, w * 0.08, h * 0.55)
      ..close();
    canvas.drawPath(path, paint);

    final eye = Paint()..color = const Color(0xFF5865F2);
    canvas.drawCircle(Offset(w * 0.36, h * 0.52), h * 0.11, eye);
    canvas.drawCircle(Offset(w * 0.64, h * 0.52), h * 0.11, eye);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _YouTubeBrandIcon extends StatelessWidget {
  const _YouTubeBrandIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 18),
      painter: _YouTubeIconPainter(),
    );
  }
}

class _YouTubeIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      Radius.circular(h * 0.22),
    );
    canvas.drawRRect(r, Paint()..color = const Color(0xFFFF1744));

    final play = Path()
      ..moveTo(w * 0.4, h * 0.28)
      ..lineTo(w * 0.72, h * 0.5)
      ..lineTo(w * 0.4, h * 0.72)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
