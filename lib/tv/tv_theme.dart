import 'package:flutter/material.dart';

/// Android TV design tokens. Orvix colors, sized for viewing from a sofa.
///
/// Android TV usually reports a 960x540 logical screen (1080p at 2x), so sizes
/// here are logical pixels for that canvas.
abstract final class TvColors {
  static const primary = Color(0xFFB9FF45);
  static const lime = Color(0xFFCBFF75);
  static const background = Color(0xFF050806);
  static const canvas = Color(0xFF070A08);
  static const surface = Color(0xFF0B0F0C);
  static const card = Color(0xFF0D120E);
  static const cardRaised = Color(0xFF131A14);
  static const cardFocused = Color(0xFF1A241B);
  static const border = Color(0xFF1E2B20);
  static const borderStrong = Color(0xFF34503A);
  static const text = Color(0xFFF2F6EE);
  static const textMuted = Color(0xFFA6B1A7);
  static const textDim = Color(0xFF6F7B70);
  static const onPrimary = Color(0xFF081006);
  static const danger = Color(0xFFFF9C8F);
  static const placeholder = Color(0xFF111712);
}

abstract final class TvMetrics {
  /// Focus animations: quick enough to keep up with a held DPAD key.
  static const focusDuration = Duration(milliseconds: 130);
  static const navCollapsedWidth = 80.0;
  static const navExpandedWidth = 236.0;

  /// Content padding. Together with the navigation width this keeps every
  /// control inside the 5% overscan-safe area.
  static const pageHorizontal = 36.0;
  static const pageTop = 28.0;
  static const pageBottom = 32.0;
  static const radius = 16.0;
  static const focusBorder = 2.5;

  /// Extra space kept around a focused control when it is scrolled into view.
  static const revealMargin = 48.0;
}

abstract final class TvText {
  static const display = TextStyle(
    fontSize: 34,
    height: 1.08,
    fontWeight: FontWeight.w900,
    letterSpacing: -.6,
    color: TvColors.text,
  );
  static const title = TextStyle(
    fontSize: 27,
    height: 1.15,
    fontWeight: FontWeight.w900,
    letterSpacing: -.35,
    color: TvColors.text,
  );
  static const section = TextStyle(
    fontSize: 19,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -.15,
    color: TvColors.text,
  );
  static const body = TextStyle(
    fontSize: 15,
    height: 1.45,
    color: TvColors.textMuted,
  );
  static const label = TextStyle(
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w800,
  );
  static const caption = TextStyle(
    fontSize: 12.5,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: TvColors.textMuted,
  );
}
