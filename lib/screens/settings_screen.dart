import 'package:flutter/material.dart';

import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _aiSinhala;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    if (mounted) setState(() => _aiSinhala = enabled);
  }

  Future<void> _setAiSinhala(bool enabled) async {
    setState(() => _aiSinhala = enabled);
    await AiSinhalaPreferencesService.setEnabled(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'AI Sinhala subtitles enabled. Orvix will prepare Sinhala subtitles before playback when possible.'
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
                          ? 'Prepare a Sinhala subtitle buffer before playback, then keep translating ahead in the background. Requires internet.'
                          : 'Sign in to your Orvix account first. When enabled, Orvix prepares Sinhala subtitles before playback and keeps translating ahead.',
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Beta note: Orvix uses an available English text subtitle as the translation source. If no suitable subtitle is found, playback continues normally with the original subtitle options.',
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFF9CA99E)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
