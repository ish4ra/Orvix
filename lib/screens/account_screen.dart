import 'package:flutter/material.dart';

import '../services/account_service.dart';
import '../services/cloud_sync_service.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.account,
    required this.cloudSync,
    required this.onDataChanged,
  });

  final AccountService account;
  final CloudSyncService cloudSync;
  final VoidCallback onDataChanged;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  bool _createAccount = false;
  bool _hidePassword = true;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(_refresh);
    widget.cloudSync.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.account.removeListener(_refresh);
    widget.cloudSync.removeListener(_refresh);
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _setMessage(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  String _friendlyError(Object error) {
    var text = error.toString().trim();
    for (final prefix in ['AuthException(message: ', 'Exception: ']) {
      if (text.startsWith(prefix)) text = text.substring(prefix.length);
    }
    if (text.endsWith(')')) text = text.substring(0, text.length - 1);
    return text.isEmpty ? 'Something went wrong.' : text;
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || !email.contains('@')) {
      _setMessage('Enter a valid email address.', error: true);
      return;
    }
    if (password.length < 6) {
      _setMessage('Password must be at least 6 characters.', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_createAccount) {
        final response = await widget.account.signUp(
          email: email,
          password: password,
        );
        if (response.session == null) {
          _setMessage(
            'Account created. Confirm the email from your inbox, then sign in.',
          );
        } else {
          await widget.cloudSync.syncNow();
          widget.onDataChanged();
          _setMessage('Account created. Cloud sync is active.');
        }
      } else {
        await widget.account.signIn(email: email, password: password);
        await widget.cloudSync.syncNow();
        widget.onDataChanged();
        _setMessage('Signed in. Your Orvix data is synced.');
      }
    } catch (error) {
      _setMessage(_friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await widget.cloudSync.syncNow();
    if (mounted) {
      widget.onDataChanged();
      setState(() => _busy = false);
      _setMessage(
        ok
            ? 'Sync complete.'
            : (widget.cloudSync.lastError ?? 'Nothing to sync right now.'),
        error: !ok && widget.cloudSync.lastError != null,
      );
    }
  }

  Future<void> _signOut() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.cloudSync.prepareForSignOut();
      await widget.account.signOut();
      widget.onDataChanged();
      _passwordController.clear();
      _setMessage('Signed out. Synced account data was removed from this device.');
    } catch (error) {
      _setMessage(_friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Account & Sync',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in to keep your Orvix library, watchlist, watch progress and app preferences in sync across devices.',
                style: TextStyle(color: color.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 24),
              if (!widget.account.backendConfigured)
                _SetupRequiredCard(color: color)
              else if (widget.account.signedIn)
                _signedInCard(color)
              else
                _authCard(color),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _messageIsError
                        ? color.errorContainer.withValues(alpha: .35)
                        : color.primaryContainer.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _messageIsError
                          ? color.error.withValues(alpha: .45)
                          : color.primary.withValues(alpha: .3),
                    ),
                  ),
                  child: Text(_message!),
                ),
              ],
              const SizedBox(height: 20),
              _PrivacyCard(color: color),
            ],
          ),
        ),
      ],
    );
  }

  Widget _authCard(ColorScheme color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: color.primaryContainer,
                  child: Icon(Icons.person_outline_rounded, color: color.primary),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _createAccount ? 'Create Orvix account' : 'Sign in to Orvix',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _createAccount
                            ? 'Your existing local library can be merged into the new account.'
                            : 'Existing local data is preserved and merged on your first sign-in.',
                        style: TextStyle(color: color.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _emailController,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: _hidePassword,
              autofillHints: _createAccount
                  ? const [AutofillHints.newPassword]
                  : const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _hidePassword ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _hidePassword = !_hidePassword),
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _createAccount
                              ? Icons.person_add_alt_1_rounded
                              : Icons.login_rounded,
                        ),
                  label: Text(_createAccount ? 'Create account' : 'Sign in'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _createAccount = !_createAccount;
                          _message = null;
                        }),
                  child: Text(
                    _createAccount
                        ? 'I already have an account'
                        : 'Create an account',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _signedInCard(ColorScheme color) {
    final sync = widget.cloudSync;
    final lastSync = sync.lastSyncedAt;
    final syncLabel = sync.syncing
        ? 'Syncing now…'
        : lastSync == null
            ? 'Waiting for first sync'
            : 'Last synced ${_relativeTime(lastSync)}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: color.primaryContainer,
                  child: Icon(Icons.person_rounded, color: color.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Signed in',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.account.displayEmail,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            sync.lastError == null
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                            size: 17,
                            color: sync.lastError == null
                                ? color.primary
                                : color.error,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            sync.lastError ?? syncLabel,
                            style: TextStyle(color: color.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SyncChip(Icons.video_library_outlined, 'Library'),
                _SyncChip(Icons.bookmark_border_rounded, 'Watchlist'),
                _SyncChip(Icons.play_circle_outline_rounded, 'Watch progress'),
                _SyncChip(Icons.tune_rounded, 'App settings'),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy || sync.syncing ? null : _syncNow,
                  icon: sync.syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: const Text('Sync now'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _signOut,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inSeconds < 10) return 'just now';
    if (difference.inMinutes < 1) return '${difference.inSeconds}s ago';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 17),
      label: Text(label),
    );
  }
}

class _SetupRequiredCard extends StatelessWidget {
  const _SetupRequiredCard({required this.color});

  final ColorScheme color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off_outlined, color: color.primary),
                const SizedBox(width: 10),
                const Text(
                  'Cloud backend not configured in this build',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Orvix still works completely offline. Account login becomes available when the app is built with ORVIX_SUPABASE_URL and ORVIX_SUPABASE_PUBLISHABLE_KEY.',
              style: TextStyle(color: color.onSurfaceVariant, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({required this.color});

  final ColorScheme color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: color.primary),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Local-first by design',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The app keeps working without an account or internet connection. Cloud sync only stores Orvix library/watch state and preferences. PikPak passwords, TorBox API keys and other provider credentials are intentionally excluded.',
                    style: TextStyle(color: color.onSurfaceVariant, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
