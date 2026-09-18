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
    this.compact = false,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final double width;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool compact;

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = widget.compact || constraints.maxWidth < 132;
            final radius = compact ? 10.0 : 14.0;
            final titleSize = compact ? 12.5 : 14.0;
            final detailSize = compact ? 10.5 : 12.0;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius + 3),
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
                borderRadius: BorderRadius.circular(radius),
                focusColor: Colors.transparent,
                onFocusChange: _onFocusChanged,
                onTap: widget.onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: .675,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(
                              color: const Color(0xFF171A23),
                              child: poster == null || poster.isEmpty
                                  ? const Center(
                                      child: Icon(Icons.movie_outlined, size: 36),
                                    )
                                  : Image.network(
                                      poster,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.topCenter,
                                      filterQuality: FilterQuality.medium,
                                      frameBuilder: (
                                        context,
                                        child,
                                        frame,
                                        wasSynchronouslyLoaded,
                                      ) {
                                        if (wasSynchronouslyLoaded ||
                                            frame != null) {
                                          return child;
                                        }
                                        return const Center(
                                          child: SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        );
                                      },
                                      errorBuilder: (_, __, ___) =>
                                          const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          size: 34,
                                        ),
                                      ),
                                    ),
                            ),
                            if (widget.item.isUpcoming)
                              Positioned(
                                top: 7,
                                left: 7,
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 6 : 8,
                                    vertical: compact ? 3 : 5,
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
                                      fontSize: compact ? 8 : 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: .5,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 6 : 8),
                    Text(
                      widget.item.title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: titleSize,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: compact ? 2 : 3),
                    Text(
                      [
                        widget.item.typeLabel,
                        if (widget.item.year != null) widget.item.year!,
                        if (widget.item.isUpcoming) 'Not released',
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: detailSize,
                        height: 1.15,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
