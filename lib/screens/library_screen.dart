import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/cloud_preferences_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/torbox_service.dart';
import 'android_exo_player_screen.dart';
import 'player_screen.dart';

Future<void> _openCloudPlayer(
  BuildContext context, {
  required PlaybackService playback,
  required String url,
  required String title,
}) async {
  final preference = await PlayerEnginePreferencesService.get();
  final engine = PlayerEngineRouter.choose(
    preference: preference,
    isAndroid: Platform.isAndroid,
    url: url,
    releaseHint: title,
  );

  if (engine == PlayerEngineKind.exoPlayer && Platform.isAndroid) {
    final result = await Navigator.of(context).push<AndroidExoPlayerResult>(
      MaterialPageRoute(
        builder: (_) => AndroidExoPlayerScreen(
          url: url,
          title: title,
          autoFallbackToMpv:
              preference == PlayerEnginePreference.auto,
        ),
      ),
    );
    if (!context.mounted) return;

    final shouldFallback = result?.switchToMpv == true ||
        (preference == PlayerEnginePreference.auto &&
            result?.failed == true);
    if (!shouldFallback) return;
  }

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        playback: playback,
        url: url,
        title: title,
      ),
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.pikpak,
    required this.transfer,
    required this.torbox,
    required this.cloudPreferences,
    required this.playback,
    required this.onAuthChanged,
  });

  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final TorBoxService torbox;
  final CloudPreferencesService cloudPreferences;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  CloudProvider _provider = CloudProvider.pikpak;

  @override
  void initState() {
    super.initState();
    _restorePreferred();
  }

  Future<void> _restorePreferred() async {
    final provider = await widget.cloudPreferences.getPreferred();
    if (mounted) setState(() => _provider = provider);
  }

  Future<void> _select(CloudProvider provider) async {
    setState(() => _provider = provider);
    await widget.cloudPreferences.setPreferred(provider);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          child: Row(
            children: [
              Text('Clouds', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
              const Spacer(),
              SegmentedButton<CloudProvider>(
                segments: const [
                  ButtonSegment(value: CloudProvider.pikpak, label: Text('PikPak'), icon: Icon(Icons.cloud_outlined)),
                  ButtonSegment(value: CloudProvider.torbox, label: Text('TorBox'), icon: Icon(Icons.bolt_outlined)),
                ],
                selected: {_provider},
                onSelectionChanged: (value) => _select(value.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _provider == CloudProvider.pikpak
                ? _PikPakPane(
                    key: const ValueKey('pikpak'),
                    pikpak: widget.pikpak,
                    transfer: widget.transfer,
                    playback: widget.playback,
                    onAuthChanged: widget.onAuthChanged,
                  )
                : _TorBoxPane(
                    key: const ValueKey('torbox'),
                    torbox: widget.torbox,
                    playback: widget.playback,
                    onAuthChanged: widget.onAuthChanged,
                  ),
          ),
        ),
      ],
    );
  }
}

class _PikPakPane extends StatefulWidget {
  const _PikPakPane({super.key, required this.pikpak, required this.transfer, required this.playback, required this.onAuthChanged});
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;
  @override
  State<_PikPakPane> createState() => _PikPakPaneState();
}

class _PikPakPaneState extends State<_PikPakPane> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final List<_FolderCrumb> _crumbs = [const _FolderCrumb('', 'My PikPak')];
  bool _checkingSession = true;
  bool _signedIn = false;
  bool _busy = false;
  String? _message;
  String? _verificationUrl;
  List<PikPakFile> _files = const [];

  String get _parentId => _crumbs.last.id;

  @override
  void initState() { super.initState(); _restore(); }
  @override
  void dispose() { _usernameController.dispose(); _passwordController.dispose(); super.dispose(); }

  String _formatFileSize(String? raw) {
    final bytes = int.tryParse(raw ?? '');
    if (bytes == null || bytes <= 0) return '';
    return _formatBytes(bytes);
  }

  Future<void> _restore() async {
    final signedIn = await widget.pikpak.isSignedIn;
    final username = await widget.pikpak.signedInUsername;
    if (!mounted) return;
    setState(() { _signedIn = signedIn; _checkingSession = false; if (username != null) _usernameController.text = username; });
    if (signedIn) await _refreshLibrary();
  }

  Future<void> _signIn() async {
    setState(() { _busy = true; _message = null; _verificationUrl = null; });
    try {
      final result = await widget.pikpak.login(_usernameController.text, _passwordController.text);
      if (!mounted) return;
      setState(() { _busy = false; _message = result.message; _verificationUrl = result.verificationUrl; _signedIn = result.ok; if (result.ok) _passwordController.clear(); });
      if (result.ok) { widget.onAuthChanged(); await _refreshLibrary(); }
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Sign in failed: $e'; }); }
  }

  Future<void> _openVerification() async {
    final uri = Uri.tryParse(_verificationUrl ?? '');
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _refreshLibrary() async {
    if (!_signedIn) return;
    setState(() { _busy = true; _message = 'Loading ${_crumbs.last.name}…'; });
    try {
      final files = await widget.pikpak.listFiles(parentId: _parentId);
      if (mounted) setState(() { _files = files; _busy = false; _message = null; });
    } on PikPakVerificationRequired catch (e) {
      if (mounted) setState(() { _busy = false; _verificationUrl = e.url; _message = 'PikPak needs verification.'; });
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not load PikPak: $e'; }); }
  }

  Future<void> _playFile(PikPakFile file) async {
    setState(() { _busy = true; _message = 'Preparing ${file.name}…'; });
    try {
      final url = await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
      if (url == null || url.isEmpty) throw Exception('PikPak did not return a playable link.');
      if (!mounted) return;
      setState(() { _busy = false; _message = null; });
      await _openCloudPlayer(
        context,
        playback: widget.playback,
        url: url,
        title: file.name,
      );
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not play file: $e'; }); }
  }

  Future<void> _signOut() async {
    await widget.pikpak.logout();
    if (!mounted) return;
    setState(() { _signedIn = false; _files = const []; _crumbs..clear()..add(const _FolderCrumb('', 'My PikPak')); _message = 'Signed out.'; });
    widget.onAuthChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: _signedIn ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildLogin(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: _cloudCard(
        context,
        icon: Icons.cloud_rounded,
        title: 'Connect PikPak',
        subtitle: 'Browse and play your PikPak cloud library directly inside Orvix.',
        children: [
          TextField(controller: _usernameController, enabled: !_busy, decoration: const InputDecoration(labelText: 'Email / username', prefixIcon: Icon(Icons.person_outline))),
          const SizedBox(height: 12),
          TextField(controller: _passwordController, enabled: !_busy, obscureText: true, onSubmitted: (_) => _busy ? null : _signIn(), decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline))),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: _busy ? null : _signIn, icon: const Icon(Icons.login), label: const Text('Sign in to PikPak')),
          if (_message != null) ...[const SizedBox(height: 12), Text(_message!, textAlign: TextAlign.center)],
          if (_verificationUrl != null) ...[const SizedBox(height: 10), OutlinedButton.icon(onPressed: _openVerification, icon: const Icon(Icons.verified_user_outlined), label: const Text('Open verification'))],
        ],
      ),
    ),
  );

  Widget _buildLibrary(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        if (_crumbs.length > 1) IconButton.filledTonal(onPressed: _busy ? null : () async { _crumbs.removeLast(); await _refreshLibrary(); }, icon: const Icon(Icons.arrow_back_rounded)),
        if (_crumbs.length > 1) const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_crumbs.last.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)), Text(_crumbs.map((e) => e.name).join(' / '), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))])),
        OutlinedButton.icon(onPressed: _busy ? null : _refreshLibrary, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : _signOut, child: const Text('Sign out')),
      ]),
      if (_message != null) ...[const SizedBox(height: 12), Text(_message!)],
      const SizedBox(height: 18),
      Expanded(child: ListView.separated(
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = _files[index];
          return _rowCard(
            context,
            icon: file.isFolder ? Icons.folder_rounded : Icons.movie_rounded,
            title: file.name,
            subtitle: file.isFolder ? 'Folder' : [(file.mimeType ?? file.kind), _formatFileSize(file.size)].where((e) => e.trim().isNotEmpty).join(' • '),
            trailing: file.isFolder ? Icons.chevron_right_rounded : Icons.play_circle_fill_rounded,
            onTap: _busy ? null : () async { if (file.isFolder) { _crumbs.add(_FolderCrumb(file.id, file.name)); await _refreshLibrary(); } else { await _playFile(file); } },
          );
        },
      )),
    ],
  );
}

class _TorBoxPane extends StatefulWidget {
  const _TorBoxPane({super.key, required this.torbox, required this.playback, required this.onAuthChanged});
  final TorBoxService torbox;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;
  @override
  State<_TorBoxPane> createState() => _TorBoxPaneState();
}

class _TorBoxPaneState extends State<_TorBoxPane> {
  final _apiKeyController = TextEditingController();
  bool _checking = true;
  bool _connected = false;
  bool _busy = false;
  String? _message;
  TorBoxAccount? _account;
  List<TorBoxItem> _items = const [];

  @override
  void initState() { super.initState(); _restore(); }
  @override
  void dispose() { _apiKeyController.dispose(); super.dispose(); }

  Future<void> _restore() async {
    final connected = await widget.torbox.isConnected;
    if (!mounted) return;
    setState(() { _connected = connected; _checking = false; });
    if (connected) await _refresh();
  }

  Future<void> _connectApiKey() async {
    setState(() { _busy = true; _message = null; });
    try {
      await widget.torbox.connectWithApiKey(_apiKeyController.text);
      _apiKeyController.clear();
      if (!mounted) return;
      setState(() => _connected = true);
      widget.onAuthChanged();
      await _refresh();
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _connectDevice() async {
    setState(() { _busy = true; _message = 'Starting TorBox device login…'; });
    try {
      final auth = await widget.torbox.startDeviceAuthorization();
      if (!mounted) return;
      setState(() => _busy = false);
      final authorized = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Connect TorBox'),
          content: SizedBox(
            width: 430,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Open TorBox, sign in, then enter/approve this device code.'),
              const SizedBox(height: 18),
              SelectableText(auth.code, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 7)),
              const SizedBox(height: 12),
              SelectableText(auth.friendlyVerificationUrl, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            OutlinedButton.icon(onPressed: () async { final uri = Uri.tryParse(auth.verificationUrl); if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication); }, icon: const Icon(Icons.open_in_new), label: const Text('Open TorBox')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('I authorized it')),
          ],
        ),
      );
      if (authorized != true || !mounted) return;
      setState(() { _busy = true; _message = 'Checking TorBox authorization…'; });
      final attempts = ((60 / auth.intervalSeconds).ceil()).clamp(4, 24);
      var ok = false;
      for (var i = 0; i < attempts && mounted; i++) {
        try { ok = await widget.torbox.redeemDeviceAuthorization(auth.deviceCode); } catch (_) { ok = false; }
        if (ok) break;
        await Future<void>.delayed(Duration(seconds: auth.intervalSeconds));
      }
      if (!mounted) return;
      if (!ok) { setState(() { _busy = false; _message = 'TorBox authorization is still pending. Try Device Login again.'; }); return; }
      setState(() => _connected = true);
      widget.onAuthChanged();
      await _refresh();
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _refresh() async {
    if (!_connected) return;
    setState(() { _busy = true; _message = 'Loading TorBox…'; });
    try {
      final account = await widget.torbox.account();
      final torrents = await widget.torbox.listTorrents(fresh: true);
      final web = await widget.torbox.listWebDownloads(fresh: true);
      if (!mounted) return;
      final items = [...torrents, ...web]..sort((a, b) => b.id.compareTo(a.id));
      setState(() { _account = account; _items = items; _busy = false; _message = null; });
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not load TorBox: $e'; }); }
  }

  Future<void> _play(TorBoxItem item) async {
    if (!item.isReady) { setState(() => _message = 'This TorBox item is still preparing (${item.progress.toStringAsFixed(0)}%).'); return; }
    final file = widget.torbox.choosePlayableFile(item);
    if (file == null) { setState(() => _message = 'No playable video file found inside this TorBox item.'); return; }
    setState(() { _busy = true; _message = 'Getting TorBox stream URL…'; });
    try {
      final url = await widget.torbox.requestDownloadUrl(item, file);
      if (!mounted) return;
      setState(() { _busy = false; _message = null; });
      await _openCloudPlayer(
        context,
        playback: widget.playback,
        url: url,
        title: file.name,
      );
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _logout() async {
    await widget.torbox.logout();
    if (!mounted) return;
    setState(() { _connected = false; _account = null; _items = const []; _message = 'Signed out.'; });
    widget.onAuthChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: _connected ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildLogin(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: _cloudCard(context,
        icon: Icons.bolt_rounded,
        title: 'Connect TorBox',
        subtitle: 'Use TorBox device login, or paste your API key. Orvix stores the token in secure storage.',
        children: [
          FilledButton.icon(onPressed: _busy ? null : _connectDevice, icon: const Icon(Icons.devices_rounded), label: const Text('Sign in with TorBox device code')),
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR')), Expanded(child: Divider())])),
          TextField(controller: _apiKeyController, enabled: !_busy, obscureText: true, decoration: const InputDecoration(labelText: 'TorBox API key', prefixIcon: Icon(Icons.key_rounded))),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: _busy ? null : _connectApiKey, icon: const Icon(Icons.link_rounded), label: const Text('Connect with API key')),
          if (_message != null) ...[const SizedBox(height: 12), Text(_message!, textAlign: TextAlign.center)],
        ],
      ),
    ),
  );

  Widget _buildLibrary(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_account?.email ?? 'TorBox', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          Text([if ((_account?.plan ?? '').isNotEmpty) _account!.plan!, '${_items.length} cloud item${_items.length == 1 ? '' : 's'}'].join(' • '), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        OutlinedButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : _logout, child: const Text('Sign out')),
      ]),
      if (_message != null) ...[const SizedBox(height: 12), Text(_message!)],
      const SizedBox(height: 18),
      Expanded(child: _items.isEmpty && !_busy ? const Center(child: Text('No TorBox items yet.')) : ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = _items[index];
          final status = item.isReady ? 'Ready' : '${item.state.isEmpty ? 'Preparing' : item.state} • ${item.progress.toStringAsFixed(0)}%';
          return _rowCard(context,
            icon: item.isReady ? Icons.check_circle_outline_rounded : Icons.downloading_rounded,
            title: item.name,
            subtitle: '$status • ${_formatBytes(item.size)} • ${item.files.length} file${item.files.length == 1 ? '' : 's'}',
            trailing: item.isReady ? Icons.play_circle_fill_rounded : Icons.chevron_right_rounded,
            onTap: _busy ? null : () => _play(item),
          );
        },
      )),
    ],
  );
}

Widget _cloudCard(BuildContext context, {required IconData icon, required String title, required String subtitle, required List<Widget> children}) => Container(
  padding: const EdgeInsets.all(30),
  decoration: BoxDecoration(
    color: const Color(0xFF0C110D),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: const Color(0xFF223125)),
    boxShadow: const [BoxShadow(color: Color(0x3316FF50), blurRadius: 28, spreadRadius: -12)],
  ),
  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    CircleAvatar(radius: 29, backgroundColor: Theme.of(context).colorScheme.primaryContainer, child: Icon(icon, size: 31)),
    const SizedBox(height: 15),
    Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
    const SizedBox(height: 7),
    Text(subtitle, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45)),
    const SizedBox(height: 24),
    ...children,
  ]),
);

Widget _rowCard(BuildContext context, {required IconData icon, required String title, required String subtitle, required IconData trailing, required VoidCallback? onTap}) => Container(
  decoration: BoxDecoration(color: const Color(0xFF0B100C), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1D2A20))),
  child: ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    leading: CircleAvatar(backgroundColor: const Color(0xFF142017), child: Icon(icon)),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Icon(trailing),
    onTap: onTap,
  ),
);

String _formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  const kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024;
  final value = bytes.toDouble();
  if (value >= tb) return '${(value / tb).toStringAsFixed(2)} TB';
  if (value >= gb) return '${(value / gb).toStringAsFixed(2)} GB';
  if (value >= mb) return '${(value / mb).toStringAsFixed(1)} MB';
  return '${(value / kb).toStringAsFixed(1)} KB';
}

class _FolderCrumb { const _FolderCrumb(this.id, this.name); final String id; final String name; }
