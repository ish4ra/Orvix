import 'package:supabase_flutter/supabase_flutter.dart';

class OrvixSupporter {
  const OrvixSupporter({
    required this.name,
    required this.provider,
    required this.supportType,
    required this.since,
    this.avatarUrl,
    this.profileUrl,
    this.tier,
  });

  final String name;
  final String provider;
  final String supportType;
  final DateTime since;
  final String? avatarUrl;
  final String? profileUrl;
  final String? tier;

  factory OrvixSupporter.fromJson(Map<String, dynamic> json) => OrvixSupporter(
        name: (json['display_name'] as String?)?.trim().isNotEmpty == true
            ? (json['display_name'] as String).trim()
            : 'Anonymous supporter',
        provider: (json['provider'] as String?) ?? 'supporter',
        supportType: (json['support_type'] as String?) ?? 'Supporter',
        since: DateTime.tryParse((json['supporter_since'] as String?) ?? '') ?? DateTime.now(),
        avatarUrl: json['avatar_url'] as String?,
        profileUrl: json['profile_url'] as String?,
        tier: json['tier'] as String?,
      );

  String get providerLabel => switch (provider) {
        'github' => 'GitHub Sponsors',
        'kofi' => 'Ko-fi',
        'buymeacoffee' => 'Buy Me a Coffee',
        _ => 'Supporter',
      };
}

abstract interface class SupportersRepository {
  Future<List<OrvixSupporter>> fetchPublicSupporters();
}

class SupabaseSupportersRepository implements SupportersRepository {
  SupabaseSupportersRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<OrvixSupporter>> fetchPublicSupporters() async {
    final rows = await _client
        .from('supporters')
        .select('display_name,provider,support_type,tier,avatar_url,profile_url,supporter_since')
        .eq('is_public', true)
        .eq('is_active', true)
        .order('supporter_since', ascending: false)
        .limit(250);

    return (rows as List)
        .map((row) => OrvixSupporter.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }
}

class SupportersService {
  SupportersService._();

  static SupportersRepository repository = SupabaseSupportersRepository();

  static Future<List<OrvixSupporter>> fetchPublicSupporters() =>
      repository.fetchPublicSupporters();
}
