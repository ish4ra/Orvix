import 'dart:async';

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
  final _verificationCode = TextEditingController();

  bool _busy = false;
  bool _syncing = false;
  bool _signUp = false;
  String? _message;
  String? _pendingVerificationEmail;
  Timer? _resendTimer;
  int _resendSeconds = 0;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _password.dispose();
    _verificationCode.dispose();
    super.dispose();
  }

  String _friendlyAuthMessage(AuthException error) {
    final text = error.message.trim();
    final lower = text.toLowerCase();

    if (lower.contains('security purposes') ||
        lower.contains('rate limit') ||
        lower.contains('too many requests')) {
      return 'Please wait about a minute before requesting another verification email.';
    }
    if (lower.contains('user already registered')) {
      return 'An Orvix account with this email already exists. Switch to Sign in.';
    }
    if (lower.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Your email is not verified yet. Enter the verification code from your inbox or request a new one.';
    }
    if (lower.contains('token has expired') || lower.contains('otp expired')) {
      return 'That verification code has expired. Request a new code and try again.';
    }
    if (lower.contains('invalid token') || lower.contains('invalid otp')) {
      return 'That verification code is not valid. Check the six digits and try again.';
    }

    return text.isEmpty ? 'Could not complete the account request.' : text;
  }

  void _startResendCooldown([int seconds = 60]) {
    _resendTimer?.cancel();
    if (mounted) {
      setState(() => _resendSeconds = seconds);
    }
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  void _showVerificationFor(String email, {bool startCooldown = false}) {
    _verificationCode.clear();
    setState(() {
      _pendingVerificationEmail = email;
      _message =
          'We sent a 6-digit verification code to $email. Enter it below to finish creating your Orvix account.';
    });
    if (startCooldown) {
      _startResendCooldown();
    }
  }

  void _backToSignIn() {
    _resendTimer?.cancel();
    _verificationCode.clear();
    setState(() {
      _pendingVerificationEmail = null;
      _resendSeconds = 0;
      _signUp = false;
      _message = null;
    });
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      setState(() => _message =
          'Enter a valid email and a password with at least 6 characters.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      if (_signUp) {
        final response =
            await OrvixAccountService.signUp(email: email, password: password);
        if (!mounted) return;
        if (response.session == null) {
          _showVerificationFor(email, startCooldown: true);
        } else {
          _password.clear();
          setState(() => _message =
              'Account created and your local Orvix data was synced.');
          widget.onAuthChanged();
        }
      } else {
        await OrvixAccountService.signIn(email: email, password: password);
        if (!mounted) return;
        _password.clear();
        setState(() => _message =
            'Signed in. Your local and cloud Orvix data were merged.');
        widget.onAuthChanged();
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      if (error.message.toLowerCase().contains('email not confirmed')) {
        _showVerificationFor(email);
      } else {
        setState(() => _message = _friendlyAuthMessage(error));
      }
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Could not connect to Orvix Cloud: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyEmail() async {
    final email = _pendingVerificationEmail;
    final code = _verificationCode.text.trim();
    if (email == null) return;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() =>
          _message = 'Enter the 6-digit verification code from your email.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final response = await OrvixAccountService.verifySignupOtp(
        email: email,
        token: code,
      );
      if (response.session == null) {
        await OrvixAccountService.signIn(
          email: email,
          password: _password.text,
        );
      }
      if (!mounted) return;
      _resendTimer?.cancel();
      _verificationCode.clear();
      _password.clear();
      setState(() {
        _pendingVerificationEmail = null;
        _resendSeconds = 0;
        _message =
            'Email verified. Your Orvix account is ready and cloud sync is active.';
      });
      widget.onAuthChanged();
    } on AuthException catch (error) {
      if (mounted) setState(() => _message = _friendlyAuthMessage(error));
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Could not verify your email: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resendVerification() async {
    final email = _pendingVerificationEmail;
    if (email == null || _resendSeconds > 0) return;

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await OrvixAccountService.resendSignupConfirmation(email: email);
      if (!mounted) return;
      _startResendCooldown();
      setState(
          () => _message = 'A new Orvix verification code was sent to $email.');
    } on AuthException catch (error) {
      if (!mounted) return;
      final friendly = _friendlyAuthMessage(error);
      if (error.message.toLowerCase().contains('security purposes') ||
          error.message.toLowerCase().contains('rate limit') ||
          error.message.toLowerCase().contains('too many requests')) {
        _startResendCooldown();
      }
      setState(() => _message = friendly);
    } catch (error) {
      if (mounted)
        setState(
            () => _message = 'Could not resend the verification email: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _busy = true;
      _syncing = true;
      _message = 'Syncing your Orvix data…';
    });
    try {
      await OrvixAccountService.mergeCloudIntoLocal()
          .timeout(const Duration(seconds: 20));
      if (mounted) {
        final now = DateTime.now();
        final minute = now.minute.toString().padLeft(2, '0');
        setState(() => _message = 'Sync complete • ${now.hour}:$minute');
        widget.onAuthChanged();
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _message =
              'Cloud sync timed out after 20 seconds. Your local data is safe; try again when the connection is stable.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Sync failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _syncing = false;
        });
      }
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
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                user == null
                    ? 'Optional cloud sync. Orvix still works normally without an account.'
                    : 'Signed in as ${user.email ?? 'Orvix user'}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.45),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D120E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263627)),
                ),
                child: user == null
                    ? (_pendingVerificationEmail == null
                        ? _signedOutForm()
                        : _verificationForm())
                    : _signedInCard(user),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!, style: const TextStyle(height: 1.4)),
              ],
              const SizedBox(height: 28),
              Text('What syncs',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              const _InfoLine(
                  Icons.video_library_outlined, 'Library and Watchlist'),
              const _InfoLine(Icons.play_circle_outline_rounded,
                  'Continue Watching and resume progress'),
              const _InfoLine(Icons.tune_rounded,
                  'Orvix app preferences and source settings'),
              const _InfoLine(Icons.cloud_off_outlined,
                  'PikPak/TorBox passwords, tokens and secret credentials stay local'),
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
        Text(_signUp ? 'Create account' : 'Sign in',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
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
          autofillHints: _signUp
              ? const [AutofillHints.newPassword]
              : const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _submit(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_signUp
                      ? Icons.person_add_alt_1_rounded
                      : Icons.login_rounded),
              label: Text(_signUp ? 'Create account' : 'Sign in'),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _signUp = !_signUp;
                        _message = null;
                      }),
              child: Text(
                  _signUp ? 'I already have an account' : 'Create an account'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _verificationForm() {
    final email = _pendingVerificationEmail!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.mark_email_read_outlined, size: 24),
            SizedBox(width: 10),
            Text('Verify your email',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'We sent a 6-digit code to $email. Enter the code here — you do not need to open a browser link.',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _verificationCode,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          onSubmitted: (_) => _busy ? null : _verifyEmail(),
          decoration: const InputDecoration(
            labelText: '6-digit verification code',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _verifyEmail,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.verified_outlined),
              label: const Text('Verify email'),
            ),
            TextButton(
              onPressed:
                  _busy || _resendSeconds > 0 ? null : _resendVerification,
              child: Text(_resendSeconds > 0
                  ? 'Resend in ${_resendSeconds}s'
                  : 'Resend code'),
            ),
            TextButton(
              onPressed: _busy ? null : _backToSignIn,
              child: const Text('Back to sign in'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'If you do not see the message, also check Spam or Junk.',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12.5),
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
              child: Text((user.email?.isNotEmpty ?? false)
                  ? user.email![0].toUpperCase()
                  : 'O'),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cloud sync active',
                      style: TextStyle(fontWeight: FontWeight.w900)),
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
              icon: _syncing
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(_syncing ? 'Syncing…' : 'Sync now'),
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
