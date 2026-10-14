import 'dart:convert';

/// Decoding and display cleanup for subtitle text shown by the Android
/// ExoPlayer screen (OpenSubtitles downloads, local files and Media3 cues).
///
/// Stray symbols on screen usually come from two places, both fixed here:
/// * a Windows-1252 file read as Latin-1, which turns curly quotes, dashes
///   and ellipses (bytes 0x80–0x9F) into invisible C1 control characters
///   that the TV font draws as boxes or "?";
/// * markup the parser leaves behind: HTML entities (`&amp;`, `&#39;`), ASS
///   hard spaces (`\h`) and zero-width characters.
class SubtitleTextCleanup {
  const SubtitleTextCleanup._();

  /// Windows-1252 code points for bytes 0x80–0x9F (null: undefined there).
  static const List<int?> _cp1252High = [
    0x20AC, null, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, null, 0x017D, null,
    null, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, null, 0x017E, 0x0178,
  ];

  /// Decodes subtitle file bytes: UTF-8 (with or without BOM), UTF-16 with
  /// a BOM, otherwise Windows-1252, the usual encoding of older SRT files.
  static String decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes.sublist(2), littleEndian: false);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return decodeWindows1252(bytes);
    }
  }

  static String decodeWindows1252(List<int> bytes) {
    final out = StringBuffer();
    for (final byte in bytes) {
      if (byte >= 0x80 && byte <= 0x9F) {
        final code = _cp1252High[byte - 0x80];
        if (code != null) out.writeCharCode(code);
      } else {
        out.writeCharCode(byte & 0xFF);
      }
    }
    return out.toString();
  }

  static String _utf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');
  static const _named = <String, String>{
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'hellip': '…',
    'ndash': '–',
    'mdash': '—',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
  };

  /// Characters that are never visible text: C0 controls other than a line
  /// break, DEL, C1 controls, zero-width spaces/joiners and the BOM.
  static final _invisible = RegExp(
      '[\u0000-\u0009\u000B-\u001F\u007F-\u009F​-‍⁠﻿]');

  /// Cleans one cue for display. Keeps line breaks; never removes visible
  /// characters such as ♪ or text the subtitle author wrote.
  static String clean(String text) {
    var value = text
        .replaceAll(r'\h', ' ')
        .replaceAll(r'\N', '\n')
        .replaceAll(_invisible, '')
        .replaceAllMapped(_entity, (match) {
      final body = match.group(1)!;
      int? code;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        code = int.tryParse(body.substring(2), radix: 16);
      } else if (body.startsWith('#')) {
        code = int.tryParse(body.substring(1));
      } else {
        final named = _named[body.toLowerCase()];
        if (named != null) return named;
      }
      if (code == null || code <= 0 || code > 0x10FFFF) return match[0]!;
      return String.fromCharCode(code);
    });
    // An entity may have produced an invisible character.
    value = value.replaceAll(_invisible, '');
    return value
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }
}
