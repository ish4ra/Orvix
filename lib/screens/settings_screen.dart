import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/subtitle_preferences_service.dart';
import '../services/subtitle_provider_credentials_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _aiSinhala;
  String? _preferredSubtitleLanguage;
  final TextEditingController _subDlApiKeyController = TextEditingController();
  bool _subDlConfigured = false;
  bool _subDlSaving = false;
  bool _subDlKeyVisible = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    final language = await SubtitlePreferencesService.preferredLanguage();
    final subDlConfigured =
        await SubtitleProviderCredentialsService.hasSubDlApiKey();
    if (!mounted) return;
    setState(() {
      _aiSinhala = enabled;
      _preferredSubtitleLanguage =
          OnlineSubtitleService.normalizeLanguage(language);
      _subDlConfigured = subDlConfigured;
    });
  }

  Future<void> _setPreferredSubtitleLanguage(String language) async {
    final normalized = OnlineSubtitleService.normalizeLanguage(language);
    setState(() => _preferredSubtitleLanguage = normalized);
    await SubtitlePreferencesService.setPreferredLanguage(normalized);
  }

  Future<void> _saveSubDlApiKey() async {
    final key = _subDlApiKeyController.text.trim();
    if (key.isEmpty || _subDlSaving) return;
    setState(() => _subDlSaving = true);
    final valid = await OnlineSubtitleService.validateSubDlApiKey(key);
    if (!mounted) return;
    if (!valid) {
      setState(() => _subDlSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'SubDL rejected this API key or could not be reached. Check the key and try again.',
          ),
        ),
      );
      return;
    }

    await SubtitleProviderCredentialsService.setSubDlApiKey(key);
    if (!mounted) return;
    _subDlApiKeyController.clear();
    setState(() {
      _subDlConfigured = true;
      _subDlSaving = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'SubDL connected. It will be used only as a secondary AI Sinhala transcript source.',
        ),
      ),
    );
  }

  Future<void> _removeSubDlApiKey() async {
    await SubtitleProviderCredentialsService.clearSubDlApiKey();
    if (!mounted) return;
    _subDlApiKeyController.clear();
    setState(() => _subDlConfigured = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('SubDL disconnected.')),
    );
  }

  Future<void> _openSubDlApiPage() async {
    await launchUrl(
      Uri.parse('https://subdl.com/panel/api'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _setAiSinhala(bool enabled) async {
    setState(() => _aiSinhala = enabled);
    await AiSinhalaPreferencesService.setEnabled(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'AI Sinhala subtitles enabled. Orvix uses the video’s own synced English text track as the timing ground truth, prefers the embedded/exact-file English transcript, can use SubDL as an optional second transcript database, pre-translates the full transcript, then shows Sinhala on the video’s real cue events.'
              : 'AI Sinhala subtitles disabled.',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _subDlApiKeyController.dispose();
    super.dispose();
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
                          ? 'Before playback starts, Orvix selects the video’s own English text subtitle track. It first tries the embedded transcript and an exact-file OpenSubtitles REST match; if those are unavailable it safely samples native dialogue and can compare OpenSubtitles v3 plus an optional SubDL fallback. During playback, only the video’s native English cue events decide when each Sinhala line appears; provider timestamps are ignored.'
                          : 'Sign in to your Orvix account first. When enabled, Orvix prepares Sinhala subtitles before playback when a safe timing source is available.',
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Automatic mode does not trust the top-ranked online subtitle and does not load a generated external Sinhala track. The native English track remains selected but hidden and acts as the live subtitle clock. If a readable native English track or matching transcript is unavailable, Orvix keeps normal/native subtitles instead of guessing. Translation never runs per cue during normal playback.',
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
                    Row(
                      children: [
                        const Icon(Icons.add_to_queue_rounded),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'SubDL transcript fallback',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (_subDlConfigured)
                          const Chip(label: Text('Connected')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Optional second subtitle database for AI Sinhala. Orvix asks SubDL only when the primary embedded/exact OpenSubtitles path cannot identify a transcript. SubDL timestamps are never trusted; the video’s native English cue events still control Sinhala timing.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _subDlApiKeyController,
                      obscureText: !_subDlKeyVisible,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: _subDlConfigured
                            ? 'Replace SubDL API key'
                            : 'SubDL API key',
                        hintText: 'Paste your free API key',
                        prefixIcon: const Icon(Icons.key_rounded),
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _subDlKeyVisible = !_subDlKeyVisible,
                          ),
                          icon: Icon(
                            _subDlKeyVisible
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _saveSubDlApiKey(),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _subDlSaving ? null : _saveSubDlApiKey,
                          icon: _subDlSaving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.verified_rounded),
                          label: Text(
                            _subDlSaving ? 'Testing…' : 'Test & save',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _openSubDlApiPage,
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('Get free key'),
                        ),
                        if (_subDlConfigured)
                          TextButton.icon(
                            onPressed: _removeSubDlApiKey,
                            icon: const Icon(Icons.link_off_rounded),
                            label: const Text('Disconnect'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The key stays in the device secure store and is not committed to the Orvix repository.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Color(0xFF9CA99E),
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
                      title: 'OpenSubtitles v3 + REST exact-file',
                      detail:
                          'OpenSubtitles v3 powers the online picker; the official REST API is used for exact-file AI transcript identity when available.',
                    ),
                    const _AddonLine(
                      icon: Icons.library_add_rounded,
                      title: 'SubDL (optional)',
                      detail:
                          'User-keyed secondary English transcript source for AI Sinhala when the primary transcript path cannot identify a match.',
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
