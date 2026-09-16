import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import 'player_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.pikpak,
    required this.transfer,
    required this.playback,
    required this.onAuthChanged,
  });

  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
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
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final signedIn = await widget.pikpak.isSignedIn;
    final username = await widget.pikpak.signedInUsername;
    if (!mounted) return;
    setState(() {
      _signedIn = signedIn;
      _checkingSession = false;
      if (username != null) _usernameController.text = username;
    });
    if (signedIn) await _refreshLibrary();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _message = null;
      _verificationUrl = null;
    });
    try {
      final result = await widget.pikpak.login(
        _usernameController.text,
        _passwordController.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = result.message;
        _verificationUrl = result.verificationUrl;
        _signedIn = result.ok;
        if (result.ok) _passwordController.clear();
      });
      if (result.ok) {
        widget.onAuthChanged();
        await _refreshLibrary();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Sign in failed: $e';
      });
    }
  }

  Future<void> _openVerification() async {
    final raw = _verificationUrl;
    if (raw == null) return;
    final uri = Uri.tryParse(raw);
    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) setState(() => _message = 'Could not open PikPak verification URL.');
    }
  }

  Future<void> _refreshLibrary() async {
    if (!_signedIn) return;
    setState(() {
      _busy = true;
      _message = 'Loading ${_crumbs.last.name}…';
    });
    try {
      final files = await widget.pikpak.listFiles(parentId: _parentId);
      if (!mounted) return;
      setState(() {
        _files = files;
        _busy = false;
        _message = null;
      });
    } on PikPakVerificationRequired catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _verificationUrl = e.url;
        _message = 'PikPak needs verification before loading this folder.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Could not load PikPak library: $e';
      });
    }
  }

  Future<void> _openFolder(PikPakFile folder) async {
    _crumbs.add(_FolderCrumb(folder.id, folder.name));
    await _refreshLibrary();
  }

  Future<void> _goBackFolder() async {
    if (_crumbs.length <= 1) return;
    _crumbs.removeLast();
    await _refreshLibrary();
  }

  Future<void> _playFile(PikPakFile file) async {
    setState(() {
      _busy = true;
      _message = 'Preparing ${file.name}…';
    });
    try {
      final url = await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
      if (url == null || url.isEmpty) {
        throw Exception('PikPak did not return a playable link.');
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = null;
      });
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            playback: widget.playback,
            url: url,
            title: file.name,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Could not play file: $e';
      });
    }
  }

  Future<void> _signOut() async {
    await widget.pikpak.logout();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _files = const [];
      _crumbs
        ..clear()
        ..add(const _FolderCrumb('', 'My PikPak'));
      _message = 'Signed out.';
      _verificationUrl = null;
    });
    widget.onAuthChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
      child: _signedIn ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildLogin(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: const Color(0xFF11141C),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF242A39)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: const Icon(Icons.cloud_rounded, size: 32),
              ),
              const SizedBox(height: 16),
              Text(
                'Connect PikPak',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                'Connect once, then browse and play your cloud library directly inside Pikora.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 26),
              TextField(
                controller: _usernameController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Email / username',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passwordController,
                enabled: !_busy,
                obscureText: true,
                onSubmitted: (_) => _busy ? null : _signIn(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _signIn,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: const Text('Sign in to PikPak'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Text(_message!, textAlign: TextAlign.center),
              ],
              if (_verificationUrl != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openVerification,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Open PikPak verification'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Complete verification in your default browser, return here, then press Sign in again.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_crumbs.length > 1) ...[
              IconButton.filledTonal(
                tooltip: 'Back to parent folder',
                onPressed: _busy ? null : _goBackFolder,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _crumbs.last.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _crumbs.map((e) => e.name).join('  /  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _refreshLibrary,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            const SizedBox(width: 10),
            TextButton(onPressed: _busy ? null : _signOut, child: const Text('Sign out')),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!),
        ],
        if (_verificationUrl != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _openVerification,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Open verification'),
          ),
        ],
        const SizedBox(height: 22),
        Expanded(
          child: _files.isEmpty && !_busy
              ? const Center(child: Text('This folder is empty.'))
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF10131A),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: const Color(0xFF202635)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF1A1E2A),
                          child: Icon(file.isFolder ? Icons.folder_rounded : Icons.movie_rounded),
                        ),
                        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(file.isFolder ? 'Folder' : (file.mimeType ?? file.kind)),
                        trailing: Icon(file.isFolder ? Icons.chevron_right : Icons.play_circle_fill_rounded),
                        onTap: _busy
                            ? null
                            : () => file.isFolder ? _openFolder(file) : _playFile(file),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FolderCrumb {
  const _FolderCrumb(this.id, this.name);
  final String id;
  final String name;
}
