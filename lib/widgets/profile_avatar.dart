import 'dart:io';

import 'package:flutter/material.dart';

import '../services/user_profile_store.dart';

/// Circular profile image — custom photo or default oracle logo asset.
class ProfileAvatarImage extends StatelessWidget {
  final double size;
  final String? imagePath;
  final bool circular;

  const ProfileAvatarImage({
    super.key,
    required this.size,
    this.imagePath,
    this.circular = true,
  });

  @override
  Widget build(BuildContext context) {
    final path = imagePath ?? UserProfileStore.avatarPath;
    final hasFile = path != null && path.isNotEmpty && File(path).existsSync();

    Widget image;
    if (hasFile) {
      image = Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => _defaultAsset(size),
      );
    } else {
      image = _defaultAsset(size);
    }

    if (circular) {
      return ClipOval(child: SizedBox(width: size, height: size, child: image));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: size, height: size, child: image),
    );
  }

  static Widget _defaultAsset(double size) {
    return Image.asset(
      UserProfileStore.defaultAvatarAsset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => Image.asset(
        'assets/images/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// Edit Profile — tappable avatar with camera overlay.
class ProfileAvatarEditor extends StatelessWidget {
  final double size;
  final String? imagePath;
  final VoidCallback onTap;
  final bool enabled;

  const ProfileAvatarEditor({
    super.key,
    this.size = 108,
    this.imagePath,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.45),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: ProfileAvatarImage(
                    size: size,
                    imagePath: imagePath,
                  ),
                ),
              ),
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF0F0F0F), width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.camera_alt_rounded, color: Colors.black, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
