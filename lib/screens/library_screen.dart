import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/pikpak_service.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.pikpak,
    required this.onAuthChanged,
  });

  final PikPakService pikpak;
  final VoidCallback onAuthChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _checkingSession = true;
  bool _signedIn = false;
  bool _busy = false;
  String? _message;
  String? _verificationUrl;
  List<PikPakFile> _files = const [];

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
      if (mounted) {
        setState(() => _message = 'Could not open PikPak verification URL.');
      }
    }
  }

  Future<void> _refreshLibrary() async {
    if (!_signedIn) return;
    setState(() {
      _busy = true;
      _message = 'Loading your PikPak library…';
    });

    try {
      final files = await widget.pikpak.listFiles();
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
        _message = 'PikPak needs verification before loading the library.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Could not load PikPak library: $e';
      });
    }
  }

  Future<void> _signOut() async {
    await widget.pikpak.logout();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _files = const [];
      _message = 'Signed out.';
      _verificationUrl = null;
    });
    widget.onAuthChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
      child: _signedIn ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildLogin(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.cloud_circle_outlined, size: 52),
                const SizedBox(height: 12),
                Text(
                  'Connect PikPak',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in directly inside Pikora. Your password is used for the login request and is not stored by default.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
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
                    'After completing the verification in your default browser, return here and press Sign in again.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My PikPak',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 4),
                  const Text('Your cloud library — folders and playable files.'),
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
              ? const Center(child: Text('No files returned from the root folder.'))
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    return ListTile(
                      leading: Icon(
                        file.isFolder ? Icons.folder_outlined : Icons.movie_outlined,
                      ),
                      title: Text(file.name),
                      subtitle: Text(file.mimeType ?? file.kind),
                      trailing: file.isFolder
                          ? const Icon(Icons.chevron_right)
                          : const Icon(Icons.play_circle_outline),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
