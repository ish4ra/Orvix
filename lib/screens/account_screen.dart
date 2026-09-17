import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/orvix_account_service.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.onAuthChanged});

  final VoidCallback onAuthChanged;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _signUp = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      setState(() => _message = 'Enter a valid email and a password with at least 6 characters.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      if (_signUp) {
        final response = await OrvixAccountService.signUp(email: email, password: password);
        if (!mounted) return;
        if (response.session == null) {
          setState(() => _message = 'Account created. Check your email to confirm it, then sign in.');
        } else {
          setState(() => _message = 'Account created and your local Orvix data was synced.');
          widget.onAuthChanged();
        }
      } else {
        await OrvixAccountService.signIn(email: email, password: password);
        if (!mounted) return;
        setState(() => _message = 'Signed in. Your local and cloud Orvix data were merged.');
        widget.onAuthChanged();
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not connect to Orvix Cloud: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await OrvixAccountService.mergeCloudIntoLocal();
      if (mounted) {
        setState(() => _message = 'Sync complete.');
        widget.onAuthChanged();
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Sync failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.signOut();
      if (!mounted) return;
      setState(() => _message = 'Signed out. Local data stays on this device.');
      widget.onAuthChanged();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = OrvixAccountService.currentUser;
    return ListView(
      padding: const EdgeInsets.all(34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Orvix Account',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                user == null
                    ? 'Optional cloud sync. Orvix still works normally without an account.'
                    : 'Signed in as ${user.email ?? 'Orvix user'}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263627)),
                ),
                child: user == null ? _signedOutForm() : _signedInCard(user),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!, style: const TextStyle(height: 1.4)),
              ],
              const SizedBox(height: 28),
              Text('What syncs', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              const _InfoLine(Icons.video_library_outlined, 'Library and Watchlist'),
              const _InfoLine(Icons.play_circle_outline_rounded, 'Continue Watching and resume progress'),
              const _InfoLine(Icons.tune_rounded, 'Orvix app preferences and source settings'),
              const _InfoLine(Icons.cloud_off_outlined, 'PikPak/TorBox passwords, tokens and secret credentials stay local'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signedOutForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_signUp ? 'Create account' : 'Sign in', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autofillHints: _signUp ? const [AutofillHints.newPassword] : const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _submit(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_signUp ? Icons.person_add_alt_1_rounded : Icons.login_rounded),
              label: Text(_signUp ? 'Create account' : 'Sign in'),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _signUp = !_signUp),
              child: Text(_signUp ? 'I already have an account' : 'Create an account'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _signedInCard(User user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 22,
              child: Text((user.email?.isNotEmpty ?? false) ? user.email![0].toUpperCase() : 'O'),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cloud sync active', style: TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(user.email ?? user.id, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Sync now'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _signOut,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
