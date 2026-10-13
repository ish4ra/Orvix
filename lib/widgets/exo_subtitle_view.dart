import 'package:flutter/material.dart';

import '../services/exo_player_preferences_service.dart';

/// One block of subtitle text drawn in the user's [ExoSubtitleStyle].
///
/// Outline is a real stroke drawn under the text (a separate [RichText]
/// layer, so finders and screen readers see the subtitle once); drop
/// shadow, raised and depressed edges are text shadows; the background sits
/// behind each line and the window behind the whole block.
class ExoSubtitleText extends StatelessWidget {
  const ExoSubtitleText({
    super.key,
    required this.text,
    required this.style,
    this.scale = 1.0,
  });

  final String text;
  final ExoSubtitleStyle style;

  /// Multiplies the font size (phones draw slightly smaller than TVs).
  final double scale;

  static const fallbackFonts = <String>['OrvixSubtitle'];

  List<Shadow>? _shadows() {
    final edge = Color(style.edgeColor);
    final strength = style.shadowStrength;
    final size = style.fontSize * scale;
    switch (style.edge) {
      case SubtitleEdgeStyle.dropShadow:
        final offset = (size * .06).clamp(1.5, 4.0);
        return [
          Shadow(
            offset: Offset(offset, offset),
            blurRadius: 2 + 6 * strength,
            color: edge.withValues(alpha: .35 + .65 * strength),
          ),
        ];
      case SubtitleEdgeStyle.raised:
        return [
          Shadow(
            offset: const Offset(1.5, 1.5),
            blurRadius: 1.5 * strength,
            color: edge.withValues(alpha: .4 + .6 * strength),
          ),
          Shadow(
            offset: const Offset(-.75, -.75),
            color: Colors.white.withValues(alpha: .35 * strength),
          ),
        ];
      case SubtitleEdgeStyle.depressed:
        return [
          Shadow(
            offset: const Offset(-1.5, -1.5),
            blurRadius: 1.5 * strength,
            color: edge.withValues(alpha: .4 + .6 * strength),
          ),
          Shadow(
            offset: const Offset(.75, .75),
            color: Colors.white.withValues(alpha: .35 * strength),
          ),
        ];
      case SubtitleEdgeStyle.outline:
      case SubtitleEdgeStyle.none:
        return null;
    }
  }

  TextStyle _base() => TextStyle(
        fontSize: style.fontSize * scale,
        height: style.lineHeight,
        fontWeight: style.weight.fontWeight,
        fontFamily: style.typeface.fontFamily,
        fontFamilyFallback: fallbackFonts,
      );

  bool get _hasBackground => style.background && style.backgroundOpacity > 0;

  /// An invisible copy of the text that paints only the line backgrounds,
  /// under the outline and the text.
  Widget _layer(BuildContext context, TextStyle textStyle) => ExcludeSemantics(
        child: RichText(
          textAlign: style.alignment.textAlign,
          textScaler: MediaQuery.textScalerOf(context),
          // Same inherited style as the Text above it, so the layers line up.
          text: TextSpan(
            text: text,
            style: DefaultTextStyle.of(context).style.merge(textStyle),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final fill = Text(
      text,
      textAlign: style.alignment.textAlign,
      style: _base().copyWith(
        color: Color(style.textColor).withValues(alpha: style.textOpacity),
        shadows: _shadows(),
      ),
    );
    final layers = <Widget>[
      if (_hasBackground)
        _layer(
          context,
          _base().copyWith(
            color: Colors.transparent,
            background: Paint()
              ..color = Color(style.backgroundColor)
                  .withValues(alpha: style.backgroundOpacity),
          ),
        ),
      if (style.edge == SubtitleEdgeStyle.outline)
        _layer(
          context,
          _base().copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = style.outlineWidth * 2 * scale.clamp(.8, 1.2)
              ..strokeJoin = StrokeJoin.round
              ..color =
                  Color(style.edgeColor).withValues(alpha: style.textOpacity),
          ),
        ),
    ];
    final Widget content =
        layers.isEmpty ? fill : Stack(children: [...layers, fill]);
    if (style.windowOpacity <= 0) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color(style.windowColor).withValues(alpha: style.windowOpacity),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: content,
      ),
    );
  }
}
