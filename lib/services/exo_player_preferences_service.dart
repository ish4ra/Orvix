import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subtitle_preferences_service.dart';

/// Outline/edge treatment of subtitle text.
enum SubtitleEdgeStyle { none, outline, dropShadow, raised, depressed }

/// Typefaces offered for subtitles. Every choice falls back to Orvix's
/// bundled Noto Sans Sinhala, so Sinhala (including AI Sinhala files)
/// always renders.
enum SubtitleTypeface { standard, sansSerif, serif, monospace, condensed, casual }

enum SubtitleWeight { regular, medium, bold }

enum SubtitleAlignment { left, center, right }

extension SubtitleEdgeStyleLabel on SubtitleEdgeStyle {
  String get label => switch (this) {
        SubtitleEdgeStyle.none => 'None',
        SubtitleEdgeStyle.outline => 'Outline',
        SubtitleEdgeStyle.dropShadow => 'Drop shadow',
        SubtitleEdgeStyle.raised => 'Raised',
        SubtitleEdgeStyle.depressed => 'Depressed',
      };
}

extension SubtitleTypefaceLabel on SubtitleTypeface {
  String get label => switch (this) {
        SubtitleTypeface.standard => 'Default',
        SubtitleTypeface.sansSerif => 'Sans serif',
        SubtitleTypeface.serif => 'Serif',
        SubtitleTypeface.monospace => 'Monospace',
        SubtitleTypeface.condensed => 'Condensed',
        SubtitleTypeface.casual => 'Casual',
      };

  /// Android system font family names; null keeps the app font.
  String? get fontFamily => switch (this) {
        SubtitleTypeface.standard => null,
        SubtitleTypeface.sansSerif => 'sans-serif',
        SubtitleTypeface.serif => 'serif',
        SubtitleTypeface.monospace => 'monospace',
        SubtitleTypeface.condensed => 'sans-serif-condensed',
        SubtitleTypeface.casual => 'casual',
      };
}

extension SubtitleWeightLabel on SubtitleWeight {
  String get label => switch (this) {
        SubtitleWeight.regular => 'Regular',
        SubtitleWeight.medium => 'Medium',
        SubtitleWeight.bold => 'Bold',
      };

  FontWeight get fontWeight => switch (this) {
        SubtitleWeight.regular => FontWeight.w400,
        SubtitleWeight.medium => FontWeight.w600,
        SubtitleWeight.bold => FontWeight.w800,
      };
}

extension SubtitleAlignmentLabel on SubtitleAlignment {
  String get label => switch (this) {
        SubtitleAlignment.left => 'Left',
        SubtitleAlignment.center => 'Center',
        SubtitleAlignment.right => 'Right',
      };

  TextAlign get textAlign => switch (this) {
        SubtitleAlignment.left => TextAlign.left,
        SubtitleAlignment.center => TextAlign.center,
        SubtitleAlignment.right => TextAlign.right,
      };
}

/// Named colors offered in the subtitle color pickers (ARGB, opaque).
const subtitleColorChoices = <(String, int)>[
  ('White', 0xFFFFFFFF),
  ('Yellow', 0xFFFFE14D),
  ('Lime', 0xFFB9FF45),
  ('Cyan', 0xFF5CE1E6),
  ('Green', 0xFF4CD964),
  ('Pink', 0xFFFF7AC6),
  ('Red', 0xFFFF5A5A),
  ('Blue', 0xFF5AA9FF),
  ('Grey', 0xFFB8B8B8),
  ('Black', 0xFF000000),
];

String subtitleColorName(int argb) {
  for (final (name, value) in subtitleColorChoices) {
    if (value & 0xFFFFFF == argb & 0xFFFFFF) return name;
  }
  return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Every subtitle appearance setting of the ExoPlayer. Size, background
/// on/off and opacity and the bottom offset are the same settings the MPV
/// player uses (SubtitlePreferencesService); the rest are ExoPlayer's own.
@immutable
class ExoSubtitleStyle {
  const ExoSubtitleStyle({
    this.fontSize = SubtitlePreferencesService.defaultFontSize,
    this.typeface = SubtitleTypeface.standard,
    this.weight = SubtitleWeight.medium,
    this.textColor = 0xFFFFFFFF,
    this.textOpacity = 1.0,
    this.edge = SubtitleEdgeStyle.outline,
    this.edgeColor = 0xFF000000,
    this.outlineWidth = 2.0,
    this.shadowStrength = 0.6,
    this.background = SubtitlePreferencesService.defaultBackground,
    this.backgroundColor = 0xFF000000,
    this.backgroundOpacity = SubtitlePreferencesService.defaultBackgroundOpacity,
    this.windowColor = 0xFF000000,
    this.windowOpacity = 0.0,
    this.bottomOffset = SubtitlePreferencesService.defaultBottomOffset,
    this.alignment = SubtitleAlignment.center,
    this.lineHeight = 1.2,
  });

  final double fontSize;
  final SubtitleTypeface typeface;
  final SubtitleWeight weight;
  final int textColor;
  final double textOpacity;
  final SubtitleEdgeStyle edge;
  final int edgeColor;

  /// Outline stroke width in logical pixels (1–5).
  final double outlineWidth;

  /// Shadow/raised/depressed intensity (0.2–1.0).
  final double shadowStrength;

  /// Background behind each line of text.
  final bool background;
  final int backgroundColor;
  final double backgroundOpacity;

  /// Box behind the whole subtitle block (0 = none).
  final int windowColor;
  final double windowOpacity;

  /// Distance of the subtitle block from the bottom of the picture.
  final double bottomOffset;
  final SubtitleAlignment alignment;
  final double lineHeight;

  static const minFontSize = 18.0;
  static const maxFontSize = 72.0;
  static const minBottomOffset = 8.0;
  static const maxBottomOffset = 220.0;

  ExoSubtitleStyle copyWith({
    double? fontSize,
    SubtitleTypeface? typeface,
    SubtitleWeight? weight,
    int? textColor,
    double? textOpacity,
    SubtitleEdgeStyle? edge,
    int? edgeColor,
    double? outlineWidth,
    double? shadowStrength,
    bool? background,
    int? backgroundColor,
    double? backgroundOpacity,
    int? windowColor,
    double? windowOpacity,
    double? bottomOffset,
    SubtitleAlignment? alignment,
    double? lineHeight,
  }) =>
      ExoSubtitleStyle(
        fontSize: (fontSize ?? this.fontSize)
            .clamp(minFontSize, maxFontSize)
            .toDouble(),
        typeface: typeface ?? this.typeface,
        weight: weight ?? this.weight,
        textColor: textColor ?? this.textColor,
        textOpacity: (textOpacity ?? this.textOpacity).clamp(0.25, 1.0).toDouble(),
        edge: edge ?? this.edge,
        edgeColor: edgeColor ?? this.edgeColor,
        outlineWidth: (outlineWidth ?? this.outlineWidth).clamp(1.0, 5.0).toDouble(),
        shadowStrength:
            (shadowStrength ?? this.shadowStrength).clamp(0.2, 1.0).toDouble(),
        background: background ?? this.background,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        backgroundOpacity:
            (backgroundOpacity ?? this.backgroundOpacity).clamp(0.0, 1.0).toDouble(),
        windowColor: windowColor ?? this.windowColor,
        windowOpacity: (windowOpacity ?? this.windowOpacity).clamp(0.0, 1.0).toDouble(),
        bottomOffset: (bottomOffset ?? this.bottomOffset)
            .clamp(minBottomOffset, maxBottomOffset)
            .toDouble(),
        alignment: alignment ?? this.alignment,
        lineHeight: (lineHeight ?? this.lineHeight).clamp(1.0, 1.8).toDouble(),
      );

  /// The ExoPlayer-only fields, as stored.
  Map<String, Object?> toOwnJson() => {
        'typeface': typeface.name,
        'weight': weight.name,
        'textColor': textColor,
        'textOpacity': textOpacity,
        'edge': edge.name,
        'edgeColor': edgeColor,
        'outlineWidth': outlineWidth,
        'shadowStrength': shadowStrength,
        'backgroundColor': backgroundColor,
        'windowColor': windowColor,
        'windowOpacity': windowOpacity,
        'alignment': alignment.name,
        'lineHeight': lineHeight,
      };

  ExoSubtitleStyle withOwnJson(Map<String, Object?> json) {
    T pick<T extends Enum>(List<T> values, Object? raw, T fallback) {
      for (final value in values) {
        if (value.name == raw) return value;
      }
      return fallback;
    }

    double? number(Object? raw) => (raw as num?)?.toDouble();
    int? color(Object? raw) => (raw as num?)?.toInt();
    return copyWith(
      typeface: pick(SubtitleTypeface.values, json['typeface'], typeface),
      weight: pick(SubtitleWeight.values, json['weight'], weight),
      textColor: color(json['textColor']),
      textOpacity: number(json['textOpacity']),
      edge: pick(SubtitleEdgeStyle.values, json['edge'], edge),
      edgeColor: color(json['edgeColor']),
      outlineWidth: number(json['outlineWidth']),
      shadowStrength: number(json['shadowStrength']),
      backgroundColor: color(json['backgroundColor']),
      windowColor: color(json['windowColor']),
      windowOpacity: number(json['windowOpacity']),
      alignment: pick(SubtitleAlignment.values, json['alignment'], alignment),
      lineHeight: number(json['lineHeight']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExoSubtitleStyle &&
      mapEquals(toOwnJson(), other.toOwnJson()) &&
      fontSize == other.fontSize &&
      background == other.background &&
      backgroundOpacity == other.backgroundOpacity &&
      bottomOffset == other.bottomOffset;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(toOwnJson().values),
        fontSize,
        background,
        backgroundOpacity,
        bottomOffset,
      );
}

/// Fit/Fill/Zoom for the ExoPlayer picture. None of them stretch.
enum ExoAspectMode { fit, fill, zoom }

/// Saved ExoPlayer settings: subtitle style, picture mode, seek step and
/// the last subtitle/audio choices. Android Mobile and Android TV are
/// separate installs, so each keeps its own values.
class ExoPlayerPreferencesService {
  ExoPlayerPreferencesService._();

  static const styleKey = 'orvix_exo_subtitle_style_v1';
  static const aspectKey = 'orvix_exo_aspect_mode_v1';
  static const zoomKey = 'orvix_exo_zoom_v1';
  static const seekStepKey = 'orvix_exo_seek_step_v1';
  static const subtitlesEnabledKey = 'orvix_exo_subtitles_enabled_v1';
  static const subtitleLanguageKey = 'orvix_exo_subtitle_language_v1';
  static const audioLanguageKey = 'orvix_exo_audio_language_v1';

  static const seekSteps = <int>[5, 10, 15, 30, 60];
  static const defaultSeekStep = 10;
  static const defaultZoom = 1.15;
  static const minZoom = 1.05;
  static const maxZoom = 2.0;

  static Future<ExoSubtitleStyle> subtitleStyle() async {
    final prefs = await SharedPreferences.getInstance();
    var style = ExoSubtitleStyle(
      fontSize: await SubtitlePreferencesService.fontSize(),
      background: await SubtitlePreferencesService.backgroundEnabled(),
      backgroundOpacity: await SubtitlePreferencesService.backgroundOpacity(),
      bottomOffset: await SubtitlePreferencesService.bottomOffset(),
    );
    final raw = prefs.getString(styleKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) style = style.withOwnJson(json.cast<String, Object?>());
      } catch (_) {
        // A damaged value falls back to defaults rather than breaking playback.
      }
    }
    return style;
  }

  static Future<void> setSubtitleStyle(ExoSubtitleStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(styleKey, jsonEncode(style.toOwnJson()));
    await SubtitlePreferencesService.setFontSize(style.fontSize);
    await SubtitlePreferencesService.setBackgroundEnabled(style.background);
    await SubtitlePreferencesService.setBackgroundOpacity(style.backgroundOpacity);
    await SubtitlePreferencesService.setBottomOffset(style.bottomOffset);
  }

  /// Restores every subtitle appearance setting. Size, background and
  /// position are shared with MPV, so they reset there too.
  static Future<ExoSubtitleStyle> resetSubtitleStyle() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(styleKey);
    await SubtitlePreferencesService.resetAppearance();
    return subtitleStyle();
  }

  static Future<ExoAspectMode> aspectMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(aspectKey);
    for (final mode in ExoAspectMode.values) {
      if (mode.name == raw) return mode;
    }
    return ExoAspectMode.fit;
  }

  static Future<void> setAspectMode(ExoAspectMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(aspectKey, mode.name);
  }

  static Future<double> zoom() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(zoomKey) ?? defaultZoom)
        .clamp(minZoom, maxZoom)
        .toDouble();
  }

  static Future<void> setZoom(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(zoomKey, value.clamp(minZoom, maxZoom).toDouble());
  }

  static Future<int> seekStepSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(seekStepKey);
    return seekSteps.contains(value) ? value! : defaultSeekStep;
  }

  static Future<void> setSeekStepSeconds(int seconds) async {
    if (!seekSteps.contains(seconds)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(seekStepKey, seconds);
  }

  static Future<bool> subtitlesEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(subtitlesEnabledKey) ?? true;
  }

  static Future<void> setSubtitlesEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(subtitlesEnabledKey, enabled);
  }

  static Future<String?> subtitleLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(subtitleLanguageKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<void> setSubtitleLanguage(String? language) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = language?.trim().toLowerCase();
    if (clean == null || clean.isEmpty) {
      await prefs.remove(subtitleLanguageKey);
    } else {
      await prefs.setString(subtitleLanguageKey, clean);
    }
  }

  static Future<String?> audioLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(audioLanguageKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<void> setAudioLanguage(String? language) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = language?.trim().toLowerCase();
    if (clean == null || clean.isEmpty) {
      await prefs.remove(audioLanguageKey);
    } else {
      await prefs.setString(audioLanguageKey, clean);
    }
  }
}
