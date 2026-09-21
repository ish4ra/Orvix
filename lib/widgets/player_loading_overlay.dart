import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';

/// Cinematic, title-aware loading surface shared by Orvix player engines.
///
/// Uses metadata that is already cached on the selected [MediaItem], so showing
/// this screen never blocks playback on another network request.
class PlayerLoadingOverlay extends StatelessWidget {
  const PlayerLoadingOverlay({
    super.key,
    required this.title,
    this.item,
    this.message = 'Loading stream…',
    this.detail,
  });

  final String title;
  final MediaItem? item;
  final String message;
  final String? detail;

  String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String get _fallbackTitle {
    final itemTitle = _clean(item?.title);
    if (itemTitle != null) return itemTitle;
    final separator = title.indexOf(' • ');
    return (separator > 0 ? title.substring(0, separator) : title).trim();
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = _clean(item?.background) ?? _clean(item?.poster);
    final logo = _clean(item?.logo);
    final secondary = _clean(detail) ??
        (title.trim() == _fallbackTitle ? null : title.trim());

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 220),
              errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xB8000000),
                  Color(0x8A000000),
                  Color(0xF0000000),
                ],
                stops: [0, 0.48, 1],
              ),
            ),
          ),
          Center(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (logo != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 360,
                            maxHeight: 110,
                          ),
                          child: CachedNetworkImage(
                            imageUrl: logo,
                            fit: BoxFit.contain,
                            errorWidget: (_, __, ___) => Text(
                              _fallbackTitle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          _fallbackTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                      const SizedBox(height: 26),
                      const SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (secondary != null) ...[
                        const SizedBox(height: 7),
                        Text(
                          secondary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFC8C8CC),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
