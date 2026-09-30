import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/subtitle_preferences_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _aiSinhala;
  String? _preferredSubtitleLanguage;
  PlayerEnginePreference? _playerEngine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    final language = await SubtitlePreferencesService.preferredLanguage();
    final playerEngine = await PlayerEnginePreferencesService.get();
    if (!mounted) return;
    setState(() {
      _aiSinhala = enabled;
      _preferredSubtitleLanguage =
          OnlineSubtitleService.normalizeLanguage(language);
      _playerEngine = playerEngine;
    });
  }

  Future<void> _setPlayerEngine(PlayerEnginePreference value) async {
    setState(() => _playerEngine = value);
    await PlayerEnginePreferencesService.set(value);
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
              ? 'AI Sinhala subtitles enabled. Orvix uses the video’s own synced English text track as the timing ground truth, matches an OpenSubtitles transcript by dialogue, pre-translates the full transcript, then shows Sinhala on the video’s real cue events.'
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
                        Icon(Icons.play_circle_outline_rounded),
                        SizedBox(width: 10),
                        Text(
                          'Player engine',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      Platform.isAndroid
                          ? 'Choose how Orvix plays video on Android mobile and Android TV.'
                          : 'MPV is used on this platform. ExoPlayer is available on Android mobile and Android TV.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _EngineChoice(
                          selected:
                              _playerEngine == PlayerEnginePreference.auto,
                          icon: Icons.auto_awesome_rounded,
                          label: 'Auto',
                          enabled: Platform.isAndroid,
                          onPressed: () => _setPlayerEngine(
                            PlayerEnginePreference.auto,
                          ),
                        ),
                        _EngineChoice(
                          selected:
                              _playerEngine == PlayerEnginePreference.exoPlayer,
                          icon: Icons.android_rounded,
                          label: 'ExoPlayer',
                          enabled: Platform.isAndroid,
                          onPressed: () => _setPlayerEngine(
                            PlayerEnginePreference.exoPlayer,
                          ),
                        ),
                        _EngineChoice(
                          selected:
                              _playerEngine == PlayerEnginePreference.mpv ||
                              !Platform.isAndroid,
                          icon: Icons.movie_filter_rounded,
                          label: 'MPV',
                          enabled: true,
                          onPressed: () => _setPlayerEngine(
                            PlayerEnginePreference.mpv,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Auto: ExoPlayer for normal Android HTTP/HLS/cloud streams; MPV for local P2P and complex/subtitle-heavy releases. If ExoPlayer fails in Auto, Orvix falls back to MPV. Manual ExoPlayer playback also offers a clean “Use MPV” action.',
                      style: TextStyle(
                        color: Color(0xFF9CA99E),
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
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
                  title: const Row(
                    children: [
                      Text(
                        'AI Sinhala subtitles',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      SizedBox(width: 8),
                      _BetaBadge(),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      AiSinhalaSubtitleService.canTranslate
                          ? 'BETA • Currently available for Free P2P playback only. AI Sinhala is temporarily unavailable for TorBox, Real-Debrid, Premiumize and other debrid/cloud sources while we improve reliability. Debrid playback will continue normally with native/English subtitles even when this switch is on.'
                          : 'BETA • Sign in to your Orvix account first. AI Sinhala is currently limited to Free P2P playback; debrid/cloud sources continue with normal subtitles.',
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Automatic mode does not trust provider timestamps and does not require users to configure subtitle API keys. OpenSubtitles and the server-side SubDL fallback are built into the AI Sinhala transcript pipeline, while the native English track remains selected but hidden as the live subtitle clock. If no safe transcript can be verified, Orvix keeps normal/native subtitles instead of guessing.',
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
                      title: 'OpenSubtitles + SubDL fallback',
                      detail:
                          'OpenSubtitles v3 powers the online picker; AI Sinhala also uses official OpenSubtitles exact-file matching and a server-side SubDL transcript fallback automatically.',
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

class _EngineChoice extends StatefulWidget {
  const _EngineChoice({
    required this.selected,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_EngineChoice> createState() => _EngineChoiceState();
}

class _EngineChoiceState extends State<_EngineChoice> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      decoration: BoxDecoration(
        color: widget.selected
            ? primary.withValues(alpha: .13)
            : const Color(0xFF151A16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused
              ? Colors.white
              : widget.selected
                  ? primary.withValues(alpha: .7)
                  : const Color(0xFF303832),
          width: _focused ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: widget.enabled,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.enabled ? widget.onPressed : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.selected ? Icons.check_rounded : widget.icon,
                  size: 18,
                  color: widget.enabled
                      ? widget.selected
                          ? primary
                          : const Color(0xFFD2D8D3)
                      : const Color(0xFF646C66),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.enabled
                        ? const Color(0xFFE8ECE9)
                        : const Color(0xFF646C66),
                    fontWeight: FontWeight.w800,
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


class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFB9FF45).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFB9FF45).withValues(alpha: 0.45)),
      ),
      child: const Text(
        'BETA',
        style: TextStyle(
          color: Color(0xFFB9FF45),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
