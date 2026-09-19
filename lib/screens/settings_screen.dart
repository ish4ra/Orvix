import 'package:flutter/material.dart';

import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/subtitle_preferences_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _aiSinhala;
  String? _preferredSubtitleLanguage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    final language = await SubtitlePreferencesService.preferredLanguage();
    if (!mounted) return;
    setState(() {
      _aiSinhala = enabled;
      _preferredSubtitleLanguage =
          OnlineSubtitleService.normalizeLanguage(language);
    });
  }

  Future<void> _setPreferredSubtitleLanguage(String language) async {
    final normalized = OnlineSubtitleService.normalizeLanguage(language);
    setState(() => _preferredSubtitleLanguage = normalized);
    await SubtitlePreferencesService.setPreferredLanguage(normalized);
  }

  Future<void> _setAiSinhala(bool enabled) async {
    setState(() => _aiSinhala = enabled);
    await AiSinhalaPreferencesService.setEnabled(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'AI Sinhala subtitles enabled. Orvix first extracts the exact English subtitle from the video itself, translates the whole file, and loads the generated Sinhala SRT as a normal player subtitle. Exact-hash OpenSubtitles is the fallback.'
              : 'AI Sinhala subtitles disabled.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _aiSinhala;
    return ListView(
      padding: const EdgeInsets.all(34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Playback and subtitle preferences for Orvix.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 26),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: SwitchListTile.adaptive(
                  value: enabled ?? false,
                  onChanged: enabled == null ? null : _setAiSinhala,
                  secondary: const Icon(Icons.translate_rounded),
                  title: const Text(
                    'AI Sinhala subtitles',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      AiSinhalaSubtitleService.canTranslate
                          ? 'Before playback starts, Orvix prefers an English text subtitle embedded in the selected video/torrent, preserves its timestamps, translates the complete file to Sinhala, caches an SRT, and loads it as a normal subtitle track. If extraction is unavailable, exact-hash OpenSubtitles is tried. Requires internet for translation.'
                          : 'Sign in to your Orvix account first. When enabled, Orvix prepares Sinhala subtitles before playback when a safe timing source is available.',
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Generated-file mode: no fuzzy cue matching and no per-cue live translation. Pause, seek and resume timing are handled by the player from the generated Sinhala subtitle file.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.5, color: Color(0xFF9CA99E)),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.closed_caption_rounded),
                        SizedBox(width: 10),
                        Text(
                          'Online subtitle language',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'OpenSubtitles v3 is built into Orvix. This language is placed first in the online subtitle picker, but every language returned by the addon remains selectable.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: 300,
                      child: DropdownButtonFormField<String>(
                        value: _preferredSubtitleLanguage ??
                            SubtitlePreferencesService.defaultPreferredLanguage,
                        decoration: const InputDecoration(
                          labelText: 'Preferred language',
                          prefixIcon: Icon(Icons.language_rounded),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'eng',
                            child: Text('English'),
                          ),
                          DropdownMenuItem(
                            value: 'sin',
                            child: Text('Sinhala'),
                          ),
                          DropdownMenuItem(
                            value: 'tam',
                            child: Text('Tamil'),
                          ),
                          DropdownMenuItem(
                            value: 'hin',
                            child: Text('Hindi'),
                          ),
                          DropdownMenuItem(
                            value: 'spa',
                            child: Text('Spanish'),
                          ),
                          DropdownMenuItem(
                            value: 'fre',
                            child: Text('French'),
                          ),
                          DropdownMenuItem(
                            value: 'ger',
                            child: Text('German'),
                          ),
                          DropdownMenuItem(
                            value: 'ita',
                            child: Text('Italian'),
                          ),
                          DropdownMenuItem(
                            value: 'por',
                            child: Text('Portuguese'),
                          ),
                          DropdownMenuItem(
                            value: 'dut',
                            child: Text('Dutch'),
                          ),
                          DropdownMenuItem(
                            value: 'rus',
                            child: Text('Russian'),
                          ),
                          DropdownMenuItem(
                            value: 'ara',
                            child: Text('Arabic'),
                          ),
                          DropdownMenuItem(
                            value: 'jpn',
                            child: Text('Japanese'),
                          ),
                          DropdownMenuItem(
                            value: 'kor',
                            child: Text('Korean'),
                          ),
                          DropdownMenuItem(
                            value: 'chi',
                            child: Text('Chinese'),
                          ),
                          DropdownMenuItem(
                            value: 'ind',
                            child: Text('Indonesian'),
                          ),
                          DropdownMenuItem(
                            value: 'tur',
                            child: Text('Turkish'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            _setPreferredSubtitleLanguage(value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Built-in addon stack',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const _AddonLine(
                      icon: Icons.movie_filter_outlined,
                      title: 'AIO Metadata + Cinemeta',
                      detail:
                          'Rich metadata first, with Cinemeta v3 as the built-in movie/series fallback.',
                    ),
                    const _AddonLine(
                      icon: Icons.subtitles_rounded,
                      title: 'OpenSubtitles v3',
                      detail:
                          'Online subtitles from the official Stremio OpenSubtitles v3 addon, selectable by language in the player.',
                    ),
                    const _AddonLine(
                      icon: Icons.hub_rounded,
                      title: 'Torrentio + provider pool',
                      detail:
                          'Torrentio-compatible results plus the default Comet and MediaFusion provider pool. AIOStreams remains optional.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AddonLine extends StatelessWidget {
  const _AddonLine({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.4,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
