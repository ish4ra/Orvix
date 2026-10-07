import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../utils/tv_keys.dart';
import 'tv_focus.dart';
import 'tv_theme.dart';

/// Decoded size for an image shown [logicalWidth] wide, so TV never decodes
/// full-resolution artwork for a small card.
int tvCacheWidth(BuildContext context, double logicalWidth,
    {int min = 160, int max = 1280}) {
  final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
  return (logicalWidth * ratio).round().clamp(min, max).toInt();
}

/// Network artwork with a designed placeholder instead of an empty or broken
/// box while loading, when missing, and when it fails.
class TvNetworkImage extends StatelessWidget {
  const TvNetworkImage({
    super.key,
    required this.url,
    required this.cacheWidth,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
  });

  final String? url;
  final int cacheWidth;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final fallback =
        placeholder ?? const ColoredBox(color: TvColors.placeholder);
    final value = url?.trim() ?? '';
    if (value.isEmpty) return fallback;
    return CachedNetworkImage(
      imageUrl: value,
      fit: fit,
      alignment: alignment,
      memCacheWidth: cacheWidth,
      fadeInDuration: const Duration(milliseconds: 120),
      fadeOutDuration: Duration.zero,
      useOldImageOnUrlChange: true,
      placeholder: (_, __) => fallback,
      errorWidget: (_, __, ___) => fallback,
    );
  }
}

/// Shown instead of a missing poster: the title on a quiet Orvix surface.
class TvPosterPlaceholder extends StatelessWidget {
  const TvPosterPlaceholder({super.key, required this.title, this.icon});

  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF151D16), Color(0xFF0B100C)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon ?? Icons.movie_outlined,
                color: TvColors.textDim, size: 30),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TvColors.textMuted,
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum TvButtonKind { primary, secondary, quiet }

/// A remote button. It stays focusable while [busy] or disabled, showing a
/// spinner or dimmed look instead of dropping focus.
class TvButton extends StatelessWidget {
  const TvButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = TvButtonKind.secondary,
    this.busy = false,
    this.enabled = true,
    this.selected = false,
    this.focusNode,
    this.autofocus = false,
    this.preferred = false,
    this.expanded = false,
    this.onFocusChange,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final TvButtonKind kind;

  /// Fills the available width (form buttons), keeping DPAD Up/Down in a
  /// form a straight line.
  final bool expanded;
  final bool busy;
  final bool enabled;

  /// For toggles such as "In Library": the icon is drawn in lime.
  final bool selected;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool preferred;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final active = enabled && !busy && onPressed != null;
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      preferred: preferred,
      enabled: active,
      onPressed: onPressed,
      onFocusChange: onFocusChange,
      semanticLabel: label,
      builder: (context, focused) {
        final primary = kind == TvButtonKind.primary;
        final background = switch (kind) {
          TvButtonKind.primary => focused ? TvColors.lime : TvColors.primary,
          TvButtonKind.secondary =>
            focused ? TvColors.cardFocused : TvColors.cardRaised,
          TvButtonKind.quiet =>
            focused ? TvColors.cardFocused : Colors.transparent,
        };
        final foreground = primary
            ? TvColors.onPrimary
            : focused
                ? TvColors.text
                : TvColors.textMuted;
        final borderColor = focused
            ? (primary ? Colors.white : TvColors.primary)
            : kind == TvButtonKind.secondary
                ? TvColors.border
                : Colors.transparent;
        return AnimatedScale(
          scale: focused ? 1.04 : 1,
          duration: TvMetrics.focusDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: active || busy ? 1 : .5,
            duration: TvMetrics.focusDuration,
            child: AnimatedContainer(
              duration: TvMetrics.focusDuration,
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: borderColor,
                  width: focused ? TvMetrics.focusBorder : 1,
                ),
              ),
              child: Row(
                mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: foreground,
                      ),
                    )
                  else if (icon != null)
                    Icon(
                      icon,
                      size: 21,
                      color:
                          selected && !primary ? TvColors.primary : foreground,
                    ),
                  if (busy || icon != null) const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TvText.label.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A tab or chip: provider tabs, filters, seasons. Selected and focused are
/// shown separately so both stay obvious.
class TvTab extends StatelessWidget {
  const TvTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    this.focusNode,
    this.autofocus = false,
    this.preferred = false,
    this.width,
    this.onFocusChange,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool preferred;

  /// A fixed width (for grids of tabs); otherwise the label decides.
  final double? width;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      preferred: preferred,
      groupSelected: selected,
      onPressed: onPressed,
      onFocusChange: onFocusChange,
      semanticLabel: label,
      builder: (context, focused) {
        final color = selected
            ? TvColors.lime
            : focused
                ? TvColors.text
                : TvColors.textMuted;
        return AnimatedScale(
          scale: focused ? 1.04 : 1,
          duration: TvMetrics.focusDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: TvMetrics.focusDuration,
            width: width,
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: focused
                  ? TvColors.cardFocused
                  : selected
                      ? const Color(0xFF16220F)
                      : TvColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: focused
                    ? TvColors.primary
                    : selected
                        ? TvColors.primary.withValues(alpha: .55)
                        : TvColors.border,
                width: focused ? TvMetrics.focusBorder : 1,
              ),
            ),
            child: Row(
              mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 20,
                      color: selected || focused
                          ? TvColors.primary
                          : TvColors.textMuted),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.label.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                    ),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: TvColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Section title inside a TV page.
class TvSectionHeader extends StatelessWidget {
  const TvSectionHeader(this.title, {super.key, this.trailing, this.padding});

  final String title;
  final String? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TvText.section,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Text(trailing!, style: TvText.caption),
          ],
        ],
      ),
    );
  }
}

/// Page title block used at the top of TV screens.
class TvPageHeader extends StatelessWidget {
  const TvPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.title),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.body,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 20),
          trailing!,
        ],
      ],
    );
  }
}

/// A poster card. The poster grows a little and gets a lime outline when
/// focused; the outline is drawn over the card so nothing shifts.
class TvPosterCard extends StatelessWidget {
  const TvPosterCard({
    super.key,
    required this.item,
    required this.width,
    required this.onPressed,
    this.onLongPress,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.preferred = false,
  });

  final MediaItem item;
  final double width;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool preferred;

  /// The total height of a card [width] wide: the poster plus its two text
  /// lines at the current text scale.
  static double heightFor(double width,
          [TextScaler textScaler = TextScaler.noScaling]) =>
      width * 1.5 +
      14 +
      textScaler.scale(13.5) * 1.2 +
      textScaler.scale(11.5) * 1.2;

  @override
  Widget build(BuildContext context) {
    final cacheWidth = tvCacheWidth(context, width, max: 520);
    final meta = [
      item.typeLabel,
      if (item.year != null) item.year!,
      if (item.isUpcoming) 'Upcoming',
    ].join(' • ');
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      preferred: preferred,
      onPressed: onPressed,
      onLongPress: onLongPress,
      onFocusChange: onFocusChange,
      semanticLabel: item.title,
      builder: (context, focused) => SizedBox(
        width: width,
        height: heightFor(width, MediaQuery.textScalerOf(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: focused ? 1.06 : 1,
              duration: TvMetrics.focusDuration,
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: TvMetrics.focusDuration,
                width: width,
                height: width * 1.5,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: focused
                      ? const [
                          BoxShadow(
                            color: Color(0x99000000),
                            blurRadius: 18,
                            offset: Offset(0, 8),
                          ),
                        ]
                      : const [],
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: focused ? TvColors.primary : const Color(0x14FFFFFF),
                    width: focused ? 3 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: TvNetworkImage(
                    url: item.poster,
                    cacheWidth: cacheWidth,
                    alignment: Alignment.topCenter,
                    placeholder: TvPosterPlaceholder(title: item.title),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: focused ? TvColors.text : TvColors.textMuted,
                fontSize: 13.5,
                height: 1.2,
                fontWeight: focused ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: TvColors.textDim,
                fontSize: 11.5,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 16:9 card for Continue Watching and episodes.
class TvLandscapeCard extends StatelessWidget {
  const TvLandscapeCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.width,
    required this.onPressed,
    this.subtitle,
    this.badge,
    this.progress,
    this.placeholderIcon,
    this.focusNode,
    this.autofocus = false,
    this.preferred = false,
    this.enabled = true,
    this.onFocusChange,
  });

  final String? imageUrl;
  final String title;
  final String? subtitle;
  final String? badge;

  /// 0..1; shown as a progress bar when set.
  final double? progress;
  final IconData? placeholderIcon;
  final double width;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool preferred;
  final bool enabled;
  final ValueChanged<bool>? onFocusChange;

  static double heightFor(double width) => width * 9 / 16;

  @override
  Widget build(BuildContext context) {
    final height = heightFor(width);
    final cacheWidth = tvCacheWidth(context, width, max: 900);
    final value = progress;
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      preferred: preferred,
      enabled: enabled,
      onPressed: onPressed,
      onFocusChange: onFocusChange,
      semanticLabel: title,
      builder: (context, focused) => AnimatedScale(
        scale: focused ? 1.05 : 1,
        duration: TvMetrics.focusDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: TvMetrics.focusDuration,
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: focused
                ? const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? TvColors.primary : const Color(0x14FFFFFF),
              width: focused ? 3 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                TvNetworkImage(
                  url: imageUrl,
                  cacheWidth: cacheWidth,
                  placeholder: ColoredBox(
                    color: TvColors.placeholder,
                    child: Align(
                      alignment: const Alignment(0, -.35),
                      child: Icon(placeholderIcon ?? Icons.movie_outlined,
                          color: TvColors.textDim, size: 30),
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x33000000),
                        Color(0xE6070A08),
                      ],
                      stops: [0, .45, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: value == null ? 12 : 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (badge != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xB3000000),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge!,
                            maxLines: 1,
                            style: const TextStyle(
                              color: TvColors.lime,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: TvColors.text,
                          fontSize: 15,
                          height: 1.2,
                          fontWeight:
                              focused ? FontWeight.w900 : FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFCBD3CC),
                            fontSize: 12,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (value != null)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: value.clamp(0, 1).toDouble(),
                        minHeight: 4,
                        backgroundColor: const Color(0x55FFFFFF),
                        valueColor:
                            const AlwaysStoppedAnimation(TvColors.primary),
                      ),
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

/// A titled horizontal row that remembers its last focused item: moving up
/// or down into the row lands where the user left it.
class TvRow extends StatefulWidget {
  const TvRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.itemBuilder,
    this.spacing = 18,
    this.trailing,
    this.horizontalPadding = TvMetrics.pageHorizontal,
  });

  final String title;
  final String? trailing;
  final int itemCount;
  final double itemWidth;
  final double itemHeight;
  final double spacing;
  final double horizontalPadding;
  final Widget Function(BuildContext context, int index, FocusNode node)
      itemBuilder;

  /// Room above and below the items for the focus scale.
  static const verticalPadding = 12.0;

  @override
  State<TvRow> createState() => _TvRowState();
}

class _TvRowState extends State<TvRow> {
  final _nodes = <int, FocusNode>{};
  int? _current;
  int? _last;

  FocusNode _nodeFor(int index) => _nodes.putIfAbsent(index, () {
        final node = FocusNode(debugLabel: '${widget.title} $index');
        node.addListener(() {
          if (node.hasPrimaryFocus) _current = index;
        });
        return node;
      });

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _handleRowFocus(bool hasFocus) {
    if (!hasFocus) {
      _last = _current;
      return;
    }
    final last = _last;
    if (last == null) return;
    final remembered = _nodes[last];
    if (!tvCanFocus(remembered) || remembered!.hasPrimaryFocus) return;
    tvRequestFocus(remembered);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TvSectionHeader(
          widget.title,
          trailing: widget.trailing,
          padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
        ),
        SizedBox(
          height: widget.itemHeight + TvRow.verticalPadding * 2,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _handleRowFocus,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: widget.horizontalPadding,
                vertical: TvRow.verticalPadding,
              ),
              itemCount: widget.itemCount,
              separatorBuilder: (_, __) => SizedBox(width: widget.spacing),
              itemBuilder: (context, index) => SizedBox(
                width: widget.itemWidth,
                child: widget.itemBuilder(context, index, _nodeFor(index)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A full-width setting: icon, title, explanation and its current value.
class TvSettingsTile extends StatelessWidget {
  const TvSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.toggle,
    this.badge,
    this.onPressed,
    this.focusNode,
    this.preferred = false,
    this.enabled = true,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// The current value, shown on the right.
  final String? value;

  /// When set, a switch showing this state is drawn on the right.
  final bool? toggle;
  final String? badge;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool preferred;
  final bool enabled;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      preferred: preferred,
      enabled: enabled,
      onPressed: onPressed,
      semanticLabel: title,
      builder: (context, focused) => AnimatedContainer(
        duration: TvMetrics.focusDuration,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: focused ? TvColors.cardFocused : TvColors.card,
          borderRadius: BorderRadius.circular(TvMetrics.radius),
          border: Border.all(
            color: focused ? TvColors.primary : TvColors.border,
            width: focused ? TvMetrics.focusBorder : 1,
          ),
        ),
        child: Opacity(
          opacity: enabled ? 1 : .5,
          child: Row(
            children: [
              Icon(icon,
                  size: 26,
                  color: focused ? TvColors.primary : TvColors.textMuted),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TvText.label.copyWith(
                              color: TvColors.text,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 10),
                          TvBadge(badge!),
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        subtitle!,
                        maxLines: focused ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TvText.caption.copyWith(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 18),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.label.copyWith(
                      color: focused ? TvColors.lime : TvColors.textMuted,
                    ),
                  ),
                ),
              ],
              if (toggle != null) ...[
                const SizedBox(width: 18),
                TvSwitch(value: toggle!, focused: focused),
              ] else if (showChevron && onPressed != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded,
                    color: focused ? TvColors.text : TvColors.textDim),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A switch drawn for TV (the tile around it takes focus).
class TvSwitch extends StatelessWidget {
  const TvSwitch({super.key, required this.value, this.focused = false});

  final bool value;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value ? 'On' : 'Off',
          style: TvText.label.copyWith(
            color: value ? TvColors.lime : TvColors.textMuted,
          ),
        ),
        const SizedBox(width: 10),
        AnimatedContainer(
          duration: TvMetrics.focusDuration,
          width: 50,
          height: 28,
          padding: const EdgeInsets.all(3),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: value ? TvColors.primary : const Color(0xFF253026),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: value ? TvColors.onPrimary : TvColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }
}

class TvBadge extends StatelessWidget {
  const TvBadge(this.label, {super.key, this.color = TvColors.primary});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          letterSpacing: .6,
        ),
      ),
    );
  }
}

/// A list row: cloud files, providers, supporters.
class TvListRow extends StatelessWidget {
  const TvListRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingIcon,
    this.onPressed,
    this.onLongPress,
    this.focusNode,
    this.preferred = false,
    this.autofocus = false,
    this.enabled = true,
    this.leading,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final IconData? trailingIcon;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool preferred;
  final bool autofocus;
  final bool enabled;

  /// Replaces the icon circle (for example an avatar).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      preferred: preferred,
      autofocus: autofocus,
      enabled: enabled,
      onPressed: onPressed,
      onLongPress: onLongPress,
      semanticLabel: title,
      builder: (context, focused) => AnimatedContainer(
        duration: TvMetrics.focusDuration,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: focused ? TvColors.cardFocused : TvColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused ? TvColors.primary : TvColors.border,
            width: focused ? TvMetrics.focusBorder : 1,
          ),
        ),
        child: Row(
          children: [
            leading ??
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: focused
                        ? TvColors.primary.withValues(alpha: .16)
                        : const Color(0xFF142017),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon,
                      size: 22,
                      color: focused ? TvColors.primary : TvColors.textMuted),
                ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.label.copyWith(
                      color: focused ? TvColors.text : const Color(0xFFDDE4DC),
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvText.caption,
                    ),
                  ],
                ],
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 12),
              Icon(trailingIcon,
                  color: focused ? TvColors.primary : TvColors.textDim),
            ],
          ],
        ),
      ),
    );
  }
}

/// A calm card for messages and empty states.
class TvMessage extends StatelessWidget {
  const TvMessage({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: TvColors.primary),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: TvText.section.copyWith(fontSize: 21)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: TvText.body),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A focusable information card, so text below the fold can be reached and
/// scrolled to with the remote.
class TvInfoCard extends StatelessWidget {
  const TvInfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    this.focusNode,
  });

  final IconData icon;
  final String title;
  final String text;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      semanticLabel: title,
      builder: (context, focused) => AnimatedContainer(
        duration: TvMetrics.focusDuration,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: focused ? TvColors.cardFocused : TvColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused ? TvColors.primary : TvColors.border,
            width: focused ? TvMetrics.focusBorder : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: TvColors.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TvText.label.copyWith(color: TvColors.text)),
                  const SizedBox(height: 4),
                  Text(text,
                      style: TvText.caption
                          .copyWith(fontWeight: FontWeight.w500, height: 1.45)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A TV list dialog: returns the chosen value, or null on Back.
Future<T?> showTvOptionsDialog<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  T? selected,
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      final height = MediaQuery.sizeOf(dialogContext).height;
      return TvHeldKeyGuard(
        child: Dialog(
          backgroundColor: TvColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: TvColors.border),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460, maxHeight: height * .8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TvText.section),
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        for (final (value, label) in options)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TvListRow(
                              icon: value == selected
                                  ? Icons.check_rounded
                                  : Icons.circle_outlined,
                              title: label,
                              autofocus: value == selected ||
                                  (selected == null &&
                                      value == options.first.$1),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(value),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
