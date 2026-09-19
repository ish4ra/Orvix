import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';

class SubDlTranscriptCandidate {
  const SubDlTranscriptCandidate({
    required this.id,
    required this.url,
    required this.label,
    required this.score,
  });

  final String id;
  final String url;
  final String label;
  final int score;
}

class SubDlTranscriptService {
  SubDlTranscriptService._();

  // Supabase public legacy anon key. This is a publishable client credential,
  // not the private SubDL key. The server-side SubDL secret lives only in the Edge Function.
  static const _guestFunctionJwt =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwanVpc3hvZndxeGhibm5zeXpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2NTMxMDIsImV4cCI6MjEwNTIyOTEwMn0.cBlT4tgZW_WMlkmOagFo7PhtFXwS7ib9Yw9BECCrNew';

  static final Uri _endpoint = Uri.parse(
    'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/subdl-transcript',
  );

  static Future<List<SubDlTranscriptCandidate>> searchEnglish({
    required MediaItem item,
    EpisodeItem? episode,
    String? releaseHint,
  }) async {
    final imdbId = item.id.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) return const [];

    final body = <String, dynamic>{
      'imdb_id': imdbId,
      'type': item.kind == MediaKind.movie ? 'movie' : 'tv',
      if (releaseHint != null && releaseHint.trim().isNotEmpty)
        'file_name': releaseHint.trim(),
      if (item.startYear != null) 'year': item.startYear,
      if (item.kind == MediaKind.series && episode != null) ...{
        'season': episode.season,
        'episode': episode.episode,
      },
    };

    try {
      final response = await http
          .post(
            _endpoint,
            headers: const {
              'Authorization': 'Bearer $_guestFunctionJwt',
              'apikey': _guestFunctionJwt,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }

      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is! Map) return const [];
      final candidates = decoded['candidates'];
      if (candidates is! List) return const [];

      final out = <SubDlTranscriptCandidate>[];
      for (final raw in candidates.whereType<Map>()) {
        final url = raw['url']?.toString().trim() ?? '';
        if (!url.startsWith(RegExp(r'https?://'))) continue;
        final label = raw['label']?.toString().trim() ?? 'SubDL subtitle';
        final score = int.tryParse(raw['score']?.toString() ?? '') ?? 520;
        out.add(
          SubDlTranscriptCandidate(
            id: raw['id']?.toString() ?? url,
            url: url,
            label: label.isEmpty ? 'SubDL subtitle' : label,
            score: score,
          ),
        );
      }
      return out;
    } catch (_) {
      // SubDL is only a secondary fallback and must never block playback.
      return const [];
    }
  }
}
