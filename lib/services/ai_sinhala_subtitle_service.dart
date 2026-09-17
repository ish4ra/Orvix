import 'package:supabase_flutter/supabase_flutter.dart';

class AiSinhalaSubtitleService {
  AiSinhalaSubtitleService._();

  static final Map<String, String> _cache = <String, String>{};

  static bool get canTranslate => Supabase.instance.client.auth.currentSession != null;

  static Future<String> translate({
    required String text,
    required String title,
    List<String> context = const <String>[],
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return '';

    final key = '$title\u0000${context.join('\u0001')}\u0000$clean';
    final cached = _cache[key];
    if (cached != null) return cached;

    final recentContext = context.length <= 6
        ? List<String>.from(context)
        : context.sublist(context.length - 6);

    final response = await Supabase.instance.client.functions.invoke(
      'translate-subtitle-si',
      body: <String, dynamic>{
        'text': clean,
        'title': title,
        'context': recentContext,
      },
    );

    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      if (data is Map && data['error'] == 'ai_not_configured') {
        throw const AiSubtitleException(
          'Orvix AI Sinhala subtitles are not configured on the server yet.',
        );
      }
      if (response.status == 429) {
        throw const AiSubtitleException(
          'AI Sinhala subtitle limit reached. Try again in a little while.',
        );
      }
      throw const AiSubtitleException('Could not translate this subtitle right now.');
    }

    final data = response.data;
    final translated = data is Map ? data['translation']?.toString().trim() : null;
    if (translated == null || translated.isEmpty) {
      throw const AiSubtitleException('The AI returned an empty subtitle.');
    }

    _cache[key] = translated;
    return translated;
  }

  static void clearSessionCache() => _cache.clear();
}

class AiSubtitleException implements Exception {
  const AiSubtitleException(this.message);
  final String message;

  @override
  String toString() => message;
}
