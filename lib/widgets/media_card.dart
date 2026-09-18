import 'package:flutter/material.dart';

import '../models/media_item.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 150,
    this.focusNode,
    this.autofocus = false,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final double width;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _focused = false;

  void _onFocusChanged(bool focused) {
    if (_focused != focused && mounted) {
      setState(() => _focused = focused);
    }
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: .45,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.item.poster;
    final focusColor = Theme.of(context).colorScheme.primary;

    return AnimatedScale(
      scale: _focused ? 1.035 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: SizedBox(
        width: widget.width,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: _focused ? 3 : 0,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: focusColor.withValues(alpha: .28),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ]
                : const [],
          ),
          padding: EdgeInsets.all(_focused ? 3 : 0),
          child: InkWell(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            canRequestFocus: true,
            borderRadius: BorderRadius.circular(14),
            focusColor: Colors.transparent,
            onFocusChange: _onFocusChanged,
            onTap: widget.onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: const Color(0xFF171A23),
                          child: poster == null || poster.isEmpty
                              ? const Center(
                                  child: Icon(Icons.movie_outlined, size: 42),
                                )
                              : Image.network(
                                  poster,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      size: 38,
                                    ),
                                  ),
                                ),
                        ),
                        if (widget.item.isUpcoming)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xE6191B24),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: focusColor),
                              ),
                              child: Text(
                                'UPCOMING',
                                style: TextStyle(
                                  color: focusColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: .7,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    widget.item.typeLabel,
                    if (widget.item.year != null) widget.item.year!,
                    if (widget.item.isUpcoming) 'Not released',
                  ].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
