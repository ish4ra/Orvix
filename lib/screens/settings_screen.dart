import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/ai_translation_credentials_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/subtitle_preferences_service.dart';
import '../services/platform_profile.dart';
import '../services/skip_segment_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';

/// Preferred online subtitle languages, in picker order.
const _subtitleLanguages = <(String, String)>[
  ('eng', 'English'),
  ('sin', 'Sinhala'),
  ('tam', 'Tamil'),
  ('hin', 'Hindi'),
  ('spa', 'Spanish'),
  ('fre', 'French'),
  ('ger', 'German'),
  ('ita', 'Italian'),
  ('por', 'Portuguese'),
  ('dut', 'Dutch'),
  ('rus', 'Russian'),
  ('ara', 'Arabic'),
  ('jpn', 'Japanese'),
  ('kor', 'Korean'),
  ('chi', 'Chinese'),
  ('ind', 'Indonesian'),
  ('tur', 'Turkish'),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _aiSinhala;
  String? _preferredSubtitleLanguage;
  PlayerEnginePreference? _playerEngine;
  bool? _skipSegments;
  bool _hasGeminiKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    final language = await SubtitlePreferencesService.preferredLanguage();
    final playerEngine = await PlayerEnginePreferencesService.get();
    final skipSegments = await SkipSegmentPreferencesService.isEnabled();
    final hasGeminiKey = await AiTranslationCredentialsService.hasGeminiApiKey();
    if (!mounted) return;
    setState(() {
      _aiSinhala = enabled;
      _preferredSubtitleLanguage =
          OnlineSubtitleService.normalizeLanguage(language);
      _playerEngine = playerEngine;
      _skipSegments = skipSegments;
      _hasGeminiKey = hasGeminiKey;
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

  Future<void> _setSkipSegments(bool enabled) async {
    setState(() => _skipSegments = enabled);
    await SkipSegmentPreferencesService.setEnabled(enabled);
  }

  Future<void> _configureGeminiKey() async {
    final controller = TextEditingController();
    var obscure = true;
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gemini API key'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI Sinhala uses your own Gemini quota. The key is stored in this device’s secure storage and is only sent to the Orvix translation endpoint for Gemini requests.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    hintText: 'Paste API key',
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(() => obscure = !obscure),
                      icon: Icon(obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (saved == null || saved.trim().isEmpty) return;
    await AiTranslationCredentialsService.setGeminiApiKey(saved);
    if (!mounted) return;
    setState(() => _hasGeminiKey = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Gemini API key saved securely on this device.')),
    );
  }

  Future<void> _removeGeminiKey() async {
    await AiTranslationCredentialsService.clearGeminiApiKey();
    if (!mounted) return;
    setState(() => _hasGeminiKey = false);
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

  String _languageLabel(String? code) {
    final value =
        code ?? SubtitlePreferencesService.defaultPreferredLanguage;
    for (final (language, label) in _subtitleLanguages) {
      if (language == value) return label;
    }
    return value.toUpperCase();
  }

  Future<void> _chooseTvSubtitleLanguage() async {
    final value = await showTvOptionsDialog<String>(
      context,
      title: 'Online subtitle language',
      options: _subtitleLanguages,
      selected: _preferredSubtitleLanguage ??
          SubtitlePreferencesService.defaultPreferredLanguage,
    );
    if (value != null && mounted) await _setPreferredSubtitleLanguage(value);
  }

  Future<void> _manageTvGeminiKey() async {
    if (!_hasGeminiKey) return _configureGeminiKey();
    final action = await showTvOptionsDialog<String>(
      context,
      title: 'Gemini translation key',
      options: const [('replace', 'Replace key'), ('remove', 'Remove key')],
      selected: 'replace',
    );
    if (!mounted) return;
    if (action == 'replace') await _configureGeminiKey();
    if (action == 'remove') await _removeGeminiKey();
  }

  Widget _tvSection(String title, List<Widget> tiles) => Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvSectionHeader(title),
            const SizedBox(height: 12),
            for (final tile in tiles) ...[
              tile,
              const SizedBox(height: 10),
            ],
          ],
        ),
      );

  Widget _buildTv(BuildContext context) {
    final engine = _playerEngine;
    const engines = [
      (PlayerEnginePreference.auto, 'Auto', Icons.auto_awesome_rounded),
      (PlayerEnginePreference.exoPlayer, 'ExoPlayer', Icons.android_rounded),
      (PlayerEnginePreference.mpv, 'MPV', Icons.movie_filter_rounded),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.pageHorizontal,
        TvMetrics.pageTop,
        TvMetrics.pageHorizontal,
        TvMetrics.pageBottom,
      ),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TvPageHeader(
                  title: 'Settings',
                  subtitle: 'Playback and subtitle preferences for Orvix.',
                ),
                const SizedBox(height: 24),
                _tvSection('Player engine', [
                  TvTabGroup(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final (value, label, icon) in engines)
                          TvTab(
                            key: ValueKey('tv-settings-engine-${value.name}'),
                            label: label,
                            icon: icon,
                            selected: engine == value,
                            preferred: value == PlayerEnginePreference.auto,
                            onPressed: () => _setPlayerEngine(value),
                          ),
                      ],
                    ),
                  ),
                  const Text(
                    'Auto: MPV on Android so embedded, external, and AI subtitles all use the subtitle-capable player path. If MPV cannot start, Orvix can fall back to ExoPlayer. Manual ExoPlayer remains a compatibility option for sources that need it, but subtitle features require MPV.',
                    style: TvText.caption,
                  ),
                ]),
                _tvSection('Playback', [
                  TvSettingsTile(
                    key: const ValueKey('tv-settings-skip'),
                    icon: Icons.fast_forward_rounded,
                    title: 'Skip intro, recap and outro',
                    subtitle:
                        'Use community timestamps from IntroDB to show skip actions during playback. Falls back to normal playback when no timestamp is available.',
                    toggle: _skipSegments ?? true,
                    enabled: _skipSegments != null,
                    onPressed: () => _setSkipSegments(!(_skipSegments ?? true)),
                  ),
                ]),
                _tvSection('Subtitles', [
                  TvSettingsTile(
                    key: const ValueKey('tv-settings-language'),
                    icon: Icons.closed_caption_rounded,
                    title: 'Online subtitle language',
                    subtitle:
                        'Placed first in the online subtitle picker. Every language returned by the addon stays selectable.',
                    value: _languageLabel(_preferredSubtitleLanguage),
                    onPressed: _chooseTvSubtitleLanguage,
                  ),
                  TvSettingsTile(
                    key: const ValueKey('tv-settings-ai-sinhala'),
                    icon: Icons.translate_rounded,
                    title: 'AI Sinhala subtitles',
                    badge: 'BETA',
                    subtitle: AiSinhalaSubtitleService.canTranslate
                        ? 'Currently available for Free P2P playback only. A Gemini API key is required and uses your own Gemini quota.'
                        : 'Sign in to your Orvix account first. AI Sinhala is currently limited to Free P2P playback.',
                    toggle: _aiSinhala ?? false,
                    enabled: _aiSinhala != null,
                    onPressed: () => _setAiSinhala(!(_aiSinhala ?? false)),
                  ),
                  TvSettingsTile(
                    key: const ValueKey('tv-settings-gemini'),
                    icon: Icons.key_rounded,
                    title: 'Gemini translation key',
                    subtitle:
                        'Required for AI Sinhala. Stored in this device’s secure storage.',
                    value: _hasGeminiKey ? 'Configured' : 'Not set',
                    onPressed: _manageTvGeminiKey,
                  ),
                ]),
                _tvSection('Built-in addon stack', const [
                  TvInfoCard(
                    icon: Icons.movie_filter_outlined,
                    title: 'AIO Metadata + Cinemeta',
                    text:
                        'Rich metadata first, with Cinemeta v3 as the built-in movie/series fallback.',
                  ),
                  TvInfoCard(
                    icon: Icons.subtitles_rounded,
                    title: 'OpenSubtitles + SubDL fallback',
                    text:
                        'OpenSubtitles v3 powers the online picker; AI Sinhala also uses official OpenSubtitles exact-file matching and a server-side SubDL transcript fallback automatically.',
                  ),
                  TvInfoCard(
                    icon: Icons.hub_rounded,
                    title: 'Torrentio + provider pool',
                    text:
                        'Torrentio-compatible results plus the default Comet and MediaFusion provider pool. AIOStreams remains optional.',
                  ),
                ]),
                _tvSection('Diagnostics', const [
                  TvInfoCard(
                    icon: Icons.shield_outlined,
                    title: 'Diagnostics',
                    text:
                        'Orvix uses limited technical diagnostics to improve reliability, performance, and compatibility across devices. Raw IP addresses, precise location, and unique hardware identifiers are not stored.',
                  ),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) return _buildTv(context);
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
                      'Auto: MPV on Android so embedded, external, and AI subtitles all use the subtitle-capable player path. If MPV cannot start, Orvix can fall back to ExoPlayer. Manual ExoPlayer remains a compatibility option for sources that need it, but subtitle features require MPV.',
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
                  value: _skipSegments ?? true,
                  onChanged: _skipSegments == null ? null : _setSkipSegments,
                  secondary: const Icon(Icons.fast_forward_rounded),
                  title: const Text(
                    'Skip intro, recap and outro',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Use community timestamps from IntroDB to show skip actions during playback. Enabled by default and falls back to normal playback when no timestamp is available.',
                      style: TextStyle(height: 1.45),
                    ),
                  ),
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
                  title: const Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'AI Sinhala subtitles',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      _BetaBadge(),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      AiSinhalaSubtitleService.canTranslate
                          ? 'BETA • Currently available for Free P2P playback only. A Gemini API key is required and uses your own Gemini quota. Debrid/cloud playback continues normally with native/English subtitles.'
                          : 'BETA • Sign in to your Orvix account first. AI Sinhala is currently limited to Free P2P playback; debrid/cloud sources continue with normal subtitles.',
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0F0C),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Gemini translation key',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _hasGeminiKey
                                ? 'Configured on this device'
                                : 'Required for AI Sinhala. Uses your own Gemini quota.',
                            style: const TextStyle(
                              color: Color(0xFF9CA99E),
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_hasGeminiKey)
                      TextButton(
                        onPressed: _removeGeminiKey,
                        child: const Text('Remove'),
                      ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _configureGeminiKey,
                      child: Text(_hasGeminiKey ? 'Replace' : 'Add key'),
                    ),
                  ],
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
                        Flexible(
                          child: Text(
                            'Online subtitle language',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
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
                        items: [
                          for (final (code, label) in _subtitleLanguages)
                            DropdownMenuItem(
                              value: code,
                              child: Text(label),
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
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Diagnostics',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Orvix uses limited technical diagnostics to improve reliability, performance, and compatibility across devices. Raw IP addresses, precise location, and unique hardware identifiers are not stored.',
                            style: TextStyle(
                              color: Color(0xFF9CA99E),
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
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
