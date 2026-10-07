import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/orvix_account_backend.dart';
import '../services/orvix_account_service.dart';
import '../services/platform_profile.dart';
import '../services/tv_device_login_service.dart';

/// Steps of the in-app forgot-password flow.
enum _RecoveryStep { email, code, newPassword, done }

/// Steps of the signed-in change-password flow. [code] is only used when the
/// backend asks the user to confirm a security code first.
enum _ChangePasswordStep { newPassword, code, done }

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
  final _recoveryCode = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _changeNewPassword = TextEditingController();
  final _changeConfirmPassword = TextEditingController();
  final _changeCode = TextEditingController();

  bool _busy = false;
  bool _syncing = false;
  bool _signUp = false;
  String? _message;
  String? _pendingVerificationEmail;
  Timer? _resendTimer;
  int _resendSeconds = 0;
  _RecoveryStep? _recoveryStep;
  String? _recoveryEmail;
  _ChangePasswordStep? _changeStep;
  String? _changeUserId;
  TvDeviceLoginState _tvLogin = const TvDeviceLoginState();
  int _tvLoginGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (PlatformProfile.isAndroidTv && OrvixAccountService.currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startTvLogin());
    }
  }

  Future<void> _startTvLogin() async {
    final generation = ++_tvLoginGeneration;
    await TvDeviceLoginService.run(
      isCancelled: () => !mounted || generation != _tvLoginGeneration,
      onState: (state) {
        if (mounted && generation == _tvLoginGeneration) {
          setState(() => _tvLogin = state);
        }
      },
    );
    if (!mounted || generation != _tvLoginGeneration) return;
    if (OrvixAccountService.currentUser != null) {
      setState(() => _tvLogin = const TvDeviceLoginState());
      try {
        await OrvixAccountService.mergeCloudIntoLocal();
      } catch (_) {}
      if (mounted) widget.onAuthChanged();
    }
  }

  void _cancelTvLogin() {
    _tvLoginGeneration++;
    if (mounted) setState(() => _tvLogin = const TvDeviceLoginState());
  }

  @override
  void dispose() {
    _tvLoginGeneration++;
    _resendTimer?.cancel();
    if (OrvixAccountService.isPasswordRecoveryVerified) {
      unawaited(OrvixAccountService.cancelPasswordRecovery());
    }
    _email.dispose();
    _password.dispose();
    _verificationCode.dispose();
    _recoveryCode.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    _changeNewPassword.dispose();
    _changeConfirmPassword.dispose();
    _changeCode.dispose();
    super.dispose();
  }

  String _friendlyAuthMessage(OrvixAuthException error) {
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
        if (!response.hasSession) {
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
    } on OrvixAuthException catch (error) {
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
      if (!response.hasSession) {
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
    } on OrvixAuthException catch (error) {
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
    } on OrvixAuthException catch (error) {
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

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  String _friendlyRecoveryMessage(OrvixAuthException error) {
    switch (error.kind) {
      case OrvixAuthErrorKind.network:
        return 'Could not reach Orvix Cloud. Check your internet connection and try again.';
      case OrvixAuthErrorKind.rateLimited:
        final seconds = error.retryAfterSeconds;
        return seconds == null
            ? 'Too many attempts. Please wait a minute and try again.'
            : 'Too many attempts. Please wait $seconds seconds and try again.';
      case OrvixAuthErrorKind.invalidCode:
        return 'That code is invalid or has expired. Check the latest Orvix email or request a new code.';
      case OrvixAuthErrorKind.invalidEmail:
        return 'Enter a valid email address.';
      case OrvixAuthErrorKind.weakPassword:
        return 'That password is too weak. Choose a longer password that is harder to guess.';
      case OrvixAuthErrorKind.samePassword:
        return 'Choose a password that is different from your current one.';
      case OrvixAuthErrorKind.sessionMissing:
        return 'Your password reset session has expired. Request a new code and try again.';
      case OrvixAuthErrorKind.reauthenticationRequired:
      case OrvixAuthErrorKind.unknown:
        return 'Could not reset your password right now. Please try again.';
    }
  }

  void _resetRecoveryState() {
    _resendTimer?.cancel();
    _resendSeconds = 0;
    _recoveryStep = null;
    _recoveryEmail = null;
    _recoveryCode.clear();
    _newPassword.clear();
    _confirmPassword.clear();
  }

  void _startRecovery() {
    _resendTimer?.cancel();
    setState(() {
      _resendSeconds = 0;
      _recoveryStep = _RecoveryStep.email;
      _message = null;
    });
  }

  Future<void> _cancelRecovery() async {
    setState(() {
      _resetRecoveryState();
      _signUp = false;
      _message = null;
      // Stay busy until the recovery session is gone, so a sign-in cannot
      // start before it is discarded.
      _busy = true;
    });
    try {
      await OrvixAccountService.cancelPasswordRecovery();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finishRecovery() {
    setState(() {
      _resetRecoveryState();
      _signUp = false;
      _message = 'Sign in with your new password.';
    });
  }

  Future<void> _sendRecoveryCode() async {
    final resend = _recoveryStep == _RecoveryStep.code;
    final email = resend ? _recoveryEmail! : _email.text.trim();
    if (resend && _resendSeconds > 0) return;
    if (!_emailPattern.hasMatch(email)) {
      setState(() => _message = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await OrvixAccountService.requestPasswordRecovery(email: email);
      if (!mounted) return;
      _recoveryCode.clear();
      setState(() {
        _recoveryEmail = email;
        _recoveryStep = _RecoveryStep.code;
        _message = resend ? 'A new reset code was requested for $email.' : null;
      });
      _startResendCooldown();
    } on OrvixAuthException catch (error) {
      if (!mounted) return;
      if (error.kind == OrvixAuthErrorKind.rateLimited) {
        // A code was requested recently, so one may already be on its way.
        setState(() {
          _recoveryEmail = email;
          _recoveryStep = _RecoveryStep.code;
          _message = _friendlyRecoveryMessage(error);
        });
        _startResendCooldown(error.retryAfterSeconds ?? 60);
      } else {
        setState(() => _message = _friendlyRecoveryMessage(error));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not reach Orvix Cloud. Check your internet connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyRecoveryCode() async {
    final email = _recoveryEmail;
    final code = _recoveryCode.text.trim();
    if (email == null) return;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _message = 'Enter the 6-digit code from your email.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await OrvixAccountService.verifyPasswordRecovery(
          email: email, token: code);
      if (!mounted) return;
      _resendTimer?.cancel();
      _recoveryCode.clear();
      setState(() {
        _resendSeconds = 0;
        _recoveryStep = _RecoveryStep.newPassword;
      });
    } on OrvixAuthException catch (error) {
      if (mounted) setState(() => _message = _friendlyRecoveryMessage(error));
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not verify the code. Check your internet connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _newPasswordProblem() =>
      _passwordProblem(_newPassword.text, _confirmPassword.text);

  String? _passwordProblem(String password, String confirmation) {
    if (password.length < OrvixAccountService.minPasswordLength) {
      return 'Use at least ${OrvixAccountService.minPasswordLength} characters for your new password.';
    }
    if (password.length > OrvixAccountService.maxPasswordLength) {
      return 'Use at most ${OrvixAccountService.maxPasswordLength} characters for your new password.';
    }
    if (password != confirmation) {
      return 'The passwords do not match.';
    }
    return null;
  }

  Future<void> _updatePassword() async {
    final problem = _newPasswordProblem();
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await OrvixAccountService.updateRecoveredPassword(
          newPassword: _newPassword.text);
      if (!mounted) return;
      _newPassword.clear();
      _confirmPassword.clear();
      _password.clear();
      _email.text = _recoveryEmail ?? _email.text;
      setState(() => _recoveryStep = _RecoveryStep.done);
    } on OrvixAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _friendlyRecoveryMessage(error);
        if (!OrvixAccountService.isPasswordRecoveryVerified) {
          // The recovery session is gone; a new code is needed.
          _newPassword.clear();
          _confirmPassword.clear();
          _recoveryStep = _RecoveryStep.code;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not update your password. Check your internet connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyChangePasswordMessage(OrvixAuthException error) {
    switch (error.kind) {
      case OrvixAuthErrorKind.network:
        return 'Could not reach Orvix Cloud. Check your internet connection and try again.';
      case OrvixAuthErrorKind.rateLimited:
        final seconds = error.retryAfterSeconds;
        return seconds == null
            ? 'Too many attempts. Please wait a minute and try again.'
            : 'Too many attempts. Please wait $seconds seconds and try again.';
      case OrvixAuthErrorKind.invalidCode:
        return 'That security code is invalid or has expired. Check the latest Orvix email or request a new code.';
      case OrvixAuthErrorKind.weakPassword:
        return 'That password is too weak. Choose a longer password that is harder to guess.';
      case OrvixAuthErrorKind.samePassword:
        return 'Choose a password that is different from your current one.';
      case OrvixAuthErrorKind.sessionMissing:
        return 'Your sign-in has expired. Sign out, sign in again, then change your password.';
      case OrvixAuthErrorKind.reauthenticationRequired:
        return 'For your security, enter the code we email you before changing your password.';
      case OrvixAuthErrorKind.invalidEmail:
      case OrvixAuthErrorKind.unknown:
        return 'Could not change your password right now. Please try again.';
    }
  }

  void _clearChangePasswordState() {
    _resendTimer?.cancel();
    _resendSeconds = 0;
    _changeStep = null;
    _changeUserId = null;
    _changeNewPassword.clear();
    _changeConfirmPassword.clear();
    _changeCode.clear();
  }

  void _startChangePassword(OrvixAccountUser user) {
    _resendTimer?.cancel();
    setState(() {
      _resendSeconds = 0;
      _changeStep = _ChangePasswordStep.newPassword;
      _changeUserId = user.id;
      _message = null;
    });
  }

  void _closeChangePassword() {
    setState(() {
      _clearChangePasswordState();
      _message = null;
    });
  }

  /// False (and the flow is closed) when the account that started the change
  /// is no longer the signed-in one.
  bool _changeAccountStillSignedIn() {
    final user = OrvixAccountService.currentUser;
    if (user != null && user.id == _changeUserId) return true;
    setState(() {
      _clearChangePasswordState();
      _message =
          'You are no longer signed in to that account. Sign in again to change its password.';
    });
    return false;
  }

  /// Asks the backend to email the security code and shows the code step.
  /// Callers manage [_busy].
  Future<void> _requestChangePasswordCode({required bool resend}) async {
    try {
      await OrvixAccountService.requestPasswordChangeCode();
      if (!mounted) return;
      _changeCode.clear();
      setState(() {
        _changeStep = _ChangePasswordStep.code;
        _message = resend ? 'A new security code was sent.' : null;
      });
      _startResendCooldown();
    } on OrvixAuthException catch (error) {
      if (!mounted) return;
      if (error.kind == OrvixAuthErrorKind.rateLimited) {
        // A code was requested recently, so one may already be on its way.
        setState(() {
          _changeStep = _ChangePasswordStep.code;
          _message = _friendlyChangePasswordMessage(error);
        });
        _startResendCooldown(error.retryAfterSeconds ?? 60);
      } else {
        setState(() => _message = _friendlyChangePasswordMessage(error));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not reach Orvix Cloud. Check your internet connection and try again.');
      }
    }
  }

  Future<void> _resendChangePasswordCode() async {
    if (_busy || _resendSeconds > 0 || !_changeAccountStillSignedIn()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _requestChangePasswordCode(resend: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitChangePassword() async {
    final withCode = _changeStep == _ChangePasswordStep.code;
    final problem = _passwordProblem(
        _changeNewPassword.text, _changeConfirmPassword.text);
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    final code = _changeCode.text.trim();
    if (withCode && !RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _message = 'Enter the 6-digit security code from your email.');
      return;
    }
    if (!_changeAccountStillSignedIn()) return;

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await OrvixAccountService.changePassword(
        newPassword: _changeNewPassword.text,
        verificationCode: withCode ? code : null,
      );
      if (!mounted) return;
      _resendTimer?.cancel();
      _changeNewPassword.clear();
      _changeConfirmPassword.clear();
      _changeCode.clear();
      setState(() {
        _resendSeconds = 0;
        _changeStep = _ChangePasswordStep.done;
      });
    } on OrvixAuthException catch (error) {
      if (!mounted) return;
      switch (error.kind) {
        case OrvixAuthErrorKind.reauthenticationRequired:
          if (withCode) {
            setState(() => _message = _friendlyChangePasswordMessage(error));
          } else {
            // Older sessions must confirm a code emailed to the account.
            await _requestChangePasswordCode(resend: false);
          }
        case OrvixAuthErrorKind.weakPassword:
        case OrvixAuthErrorKind.samePassword:
          // Start over with a different password; a code that was already
          // checked cannot be reused, so a new one is sent when needed.
          _resendTimer?.cancel();
          _changeNewPassword.clear();
          _changeConfirmPassword.clear();
          _changeCode.clear();
          setState(() {
            _resendSeconds = 0;
            _changeStep = _ChangePasswordStep.newPassword;
            _message = _friendlyChangePasswordMessage(error);
          });
        default:
          setState(() => _message = _friendlyChangePasswordMessage(error));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not change your password. Check your internet connection and try again.');
      }
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
      if (PlatformProfile.isAndroidTv) {
        unawaited(_startTvLogin());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = OrvixAccountService.currentUser;
    if (PlatformProfile.isAndroidTv) {
      return _buildTvAccount(context, user);
    }
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
                    ? (_recoveryStep != null
                        ? _recoveryForm()
                        : _pendingVerificationEmail == null
                            ? _signedOutForm()
                            : _verificationForm())
                    : (_changeStep != null && _changeUserId == user.id
                        ? _changePasswordForm(user)
                        : _signedInCard(user)),
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
                  'Connected debrid and cloud-service credentials sync securely with your Orvix account'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTvAccount(BuildContext context, OrvixAccountUser? user) {
    return _TvAccountLayout(
      user: user,
      loginState: _tvLogin,
      busy: _busy,
      syncing: _syncing,
      onRefreshLogin: _startTvLogin,
      onCancelLogin: _cancelTvLogin,
      onSync: _syncNow,
      onSignOut: _signOut,
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
        _PasswordField(
          controller: _password,
          enabled: !_busy,
          label: 'Password',
          autofillHints: _signUp
              ? const [AutofillHints.newPassword]
              : const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _submit(),
        ),
        if (!_signUp)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _startRecovery,
              child: const Text('Forgot password?'),
            ),
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

  Widget _recoveryHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 24),
        const SizedBox(width: 10),
        Flexible(
          child: Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }

  Widget _recoveryHint(String text) {
    return Text(
      text,
      style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4),
    );
  }

  Widget _busyIcon(IconData icon) => _busy
      ? const SizedBox(
          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
      : Icon(icon);

  Widget _recoveryForm() {
    final cancel = TextButton(
      onPressed: _busy ? null : _cancelRecovery,
      child: const Text('Back to sign in'),
    );
    switch (_recoveryStep!) {
      case _RecoveryStep.email:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(Icons.lock_reset_rounded, 'Reset your password'),
            const SizedBox(height: 10),
            _recoveryHint(
                'Enter the email you use for Orvix. We will email you a 6-digit code to reset your password.'),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              onSubmitted: (_) => _busy ? null : _sendRecoveryCode(),
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _sendRecoveryCode,
                  icon: _busyIcon(Icons.send_rounded),
                  label: const Text('Send reset code'),
                ),
                cancel,
              ],
            ),
          ],
        );
      case _RecoveryStep.code:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(Icons.mark_email_read_outlined, 'Check your email'),
            const SizedBox(height: 10),
            _recoveryHint(
                'If an Orvix account uses $_recoveryEmail, we sent it a 6-digit reset code. Enter the code here — you do not need to open a browser link.'),
            const SizedBox(height: 16),
            TextField(
              controller: _recoveryCode,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              autofillHints: const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _busy ? null : _verifyRecoveryCode(),
              decoration: const InputDecoration(
                labelText: '6-digit reset code',
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
                  onPressed: _busy ? null : _verifyRecoveryCode,
                  icon: _busyIcon(Icons.verified_outlined),
                  label: const Text('Verify code'),
                ),
                TextButton(
                  onPressed:
                      _busy || _resendSeconds > 0 ? null : _sendRecoveryCode,
                  child: Text(_resendSeconds > 0
                      ? 'Resend in ${_resendSeconds}s'
                      : 'Resend code'),
                ),
                cancel,
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
      case _RecoveryStep.newPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(Icons.password_rounded, 'Choose a new password'),
            const SizedBox(height: 10),
            _recoveryHint(
                'Use at least ${OrvixAccountService.minPasswordLength} characters. You will sign in with this password from now on.'),
            const SizedBox(height: 16),
            _PasswordField(
              controller: _newPassword,
              enabled: !_busy,
              label: 'New password',
              autofocus: true,
              autofillHints: const [AutofillHints.newPassword],
            ),
            const SizedBox(height: 12),
            _PasswordField(
              controller: _confirmPassword,
              enabled: !_busy,
              label: 'Confirm new password',
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _busy ? null : _updatePassword(),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _updatePassword,
                  icon: _busyIcon(Icons.check_rounded),
                  label: const Text('Update password'),
                ),
                cancel,
              ],
            ),
          ],
        );
      case _RecoveryStep.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(Icons.check_circle_outline_rounded,
                'Password updated'),
            const SizedBox(height: 10),
            _recoveryHint(
                'Your Orvix password was changed. Sign in with your new password to turn cloud sync back on.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              autofocus: true,
              onPressed: _finishRecovery,
              icon: const Icon(Icons.login_rounded),
              label: const Text('Sign in'),
            ),
          ],
        );
    }
  }

  Widget _changePasswordForm(OrvixAccountUser user) {
    final email = user.email ?? 'your account email';
    final cancel = TextButton(
      onPressed: _busy ? null : _closeChangePassword,
      child: const Text('Cancel'),
    );
    final passwordFields = <Widget>[
      _PasswordField(
        controller: _changeNewPassword,
        enabled: !_busy,
        label: 'New password',
        autofocus: _changeStep == _ChangePasswordStep.newPassword,
        autofillHints: const [AutofillHints.newPassword],
      ),
      const SizedBox(height: 12),
      _PasswordField(
        controller: _changeConfirmPassword,
        enabled: !_busy,
        label: 'Confirm new password',
        autofillHints: const [AutofillHints.newPassword],
        onSubmitted: (_) => _busy ? null : _submitChangePassword(),
      ),
    ];
    switch (_changeStep!) {
      case _ChangePasswordStep.newPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(Icons.password_rounded, 'Change password'),
            const SizedBox(height: 10),
            _recoveryHint(
                'Choose a new password for $email. Use at least ${OrvixAccountService.minPasswordLength} characters. You will stay signed in on this device.'),
            const SizedBox(height: 16),
            ...passwordFields,
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _submitChangePassword,
                  icon: _busyIcon(Icons.check_rounded),
                  label: const Text('Change password'),
                ),
                cancel,
              ],
            ),
          ],
        );
      case _ChangePasswordStep.code:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(
                Icons.verified_user_outlined, 'Confirm it\'s you'),
            const SizedBox(height: 10),
            _recoveryHint(
                'For your security, we sent a 6-digit code to $email. Enter it here to finish changing your password.'),
            const SizedBox(height: 16),
            TextField(
              controller: _changeCode,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _busy ? null : _submitChangePassword(),
              decoration: const InputDecoration(
                labelText: '6-digit security code',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            ...passwordFields,
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _submitChangePassword,
                  icon: _busyIcon(Icons.check_rounded),
                  label: const Text('Change password'),
                ),
                TextButton(
                  onPressed: _busy || _resendSeconds > 0
                      ? null
                      : _resendChangePasswordCode,
                  child: Text(_resendSeconds > 0
                      ? 'Resend in ${_resendSeconds}s'
                      : 'Resend code'),
                ),
                cancel,
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
      case _ChangePasswordStep.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryHeader(
                Icons.check_circle_outline_rounded, 'Password changed'),
            const SizedBox(height: 10),
            _recoveryHint(
                'Your Orvix password was changed. You are still signed in on this device. Other devices signed in to this account will need to sign in again with the new password.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              autofocus: true,
              onPressed: _closeChangePassword,
              icon: const Icon(Icons.done_rounded),
              label: const Text('Done'),
            ),
          ],
        );
    }
  }

  Future<void> _approveTvCode(String raw) async {
    if (OrvixAccountService.currentUser == null) {
      setState(() => _message =
          'Sign in to your Orvix account first, then scan the TV QR code.');
      return;
    }
    final uri = Uri.tryParse(raw.trim());
    final fromUrl = uri?.queryParameters['code'];
    final code = (fromUrl ?? raw)
        .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
        .toUpperCase();
    final validCode = code.length == 6 &&
        code.codeUnits.every((unit) =>
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90));
    if (!validCode) {
      setState(() =>
          _message = 'That QR code is not a valid Orvix TV login code.');
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Approving TV…';
    });
    try {
      final approved = await TvDeviceLoginService.approve(code);
      if (!mounted) return;
      setState(() => _message = approved
          ? 'TV approved. Orvix on your TV will sign in automatically.'
          : 'That TV code expired or was already used. Refresh the QR on the TV.');
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not approve the TV. Refresh its QR code and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanTvQr() async {
    if (!Platform.isAndroid || PlatformProfile.isAndroidTv || _busy) return;
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _OrvixTvQrScannerScreen()),
    );
    if (value != null && mounted) await _approveTvCode(value);
  }

  Widget _signedInCard(OrvixAccountUser user) {
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
            if (Platform.isAndroid && !PlatformProfile.isAndroidTv)
              FilledButton.icon(
                onPressed: _busy ? null : _scanTvQr,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan TV QR'),
              ),
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
              onPressed: _busy ? null : () => _startChangePassword(user),
              icon: const Icon(Icons.password_rounded),
              label: const Text('Change password'),
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

/// A password text field with a show/hide toggle. The password is hidden by
/// default; toggling keeps the entered text and cursor position.
class _PasswordField extends StatefulWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    this.enabled = true,
    this.autofocus = false,
    this.autofillHints,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final bool autofocus;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: _obscured,
      // Keep revealed passwords out of keyboard suggestions and learning.
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: widget.autofillHints,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          icon: Icon(_obscured
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined),
          onPressed: widget.enabled
              ? () => setState(() => _obscured = !_obscured)
              : null,
        ),
      ),
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


class _TvAccountLayout extends StatelessWidget {
  const _TvAccountLayout({
    required this.user,
    required this.loginState,
    required this.busy,
    required this.syncing,
    required this.onRefreshLogin,
    required this.onCancelLogin,
    required this.onSync,
    required this.onSignOut,
  });

  final OrvixAccountUser? user;
  final TvDeviceLoginState loginState;
  final bool busy;
  final bool syncing;
  final VoidCallback onRefreshLogin;
  final VoidCallback onCancelLogin;
  final VoidCallback onSync;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    const primaryText = Color(0xFFF5F7F2);
    const secondaryText = Color(0xFF9BA69C);
    const pane = Color(0x0FFFFFFF);
    const border = Color(0xFF263627);
    final signedIn = user != null;

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Container(
        color: const Color(0xFF050806),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 56),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset('assets/branding/orvix_logo.webp', height: 58, fit: BoxFit.contain),
                    const SizedBox(height: 30),
                    const Text(
                      'Your Orvix, synced across screens.',
                      style: TextStyle(
                        color: primaryText,
                        fontSize: 40,
                        height: 1.12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      signedIn
                          ? 'Connected to your Orvix account.'
                          : 'Scan the QR code with your phone to sign in without typing on your TV.',
                      style: const TextStyle(color: secondaryText, fontSize: 17, height: 1.5),
                    ),
                    if (signedIn) ...[
                      const SizedBox(height: 24),
                      Text(
                        user!.email ?? 'Orvix account',
                        style: const TextStyle(color: Color(0xFFCBFF75), fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              width: 460,
              height: double.infinity,
              decoration: const BoxDecoration(
                color: pane,
                border: Border(left: BorderSide(color: border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Center(
                child: signedIn
                    ? _TvSignedInPane(
                        email: user!.email ?? 'Orvix account',
                        busy: busy,
                        syncing: syncing,
                        onSync: onSync,
                        onSignOut: onSignOut,
                      )
                    : _TvQrPane(
                        state: loginState,
                        onRefresh: onRefreshLogin,
                        onCancel: onCancelLogin,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvQrPane extends StatelessWidget {
  const _TvQrPane({required this.state, required this.onRefresh, required this.onCancel});
  final TvDeviceLoginState state;
  final VoidCallback onRefresh;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final waiting = state.phase == TvDeviceLoginPhase.waiting || state.phase == TvDeviceLoginPhase.signingIn;
    final url = state.verificationUrl;
    final code = state.userCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Scan QR and sign in on your phone',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF9BA69C), fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 26),
        if (waiting && url != null)
          Container(
            width: 222,
            height: 222,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
            child: QrImageView(data: url, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(color: Colors.black), dataModuleStyle: const QrDataModuleStyle(color: Colors.black)),
          )
        else
          Container(
            width: 222,
            height: 222,
            decoration: BoxDecoration(
              color: const Color(0x0FFFFFFF),
              border: Border.all(color: const Color(0xFF263627)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: state.phase == TvDeviceLoginPhase.starting
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.qr_code_2_rounded, size: 82, color: Color(0xFF6E796F)),
            ),
          ),
        const SizedBox(height: 20),
        if (code != null)
          Text(
            code.length == 6 ? '${code.substring(0, 3)}-${code.substring(3)}' : code,
            style: const TextStyle(
              color: Color(0xFFF5F7F2),
              fontSize: 25,
              letterSpacing: 3,
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: 12),
        Text(
          state.phase == TvDeviceLoginPhase.signingIn
              ? 'Signing you in…'
              : state.phase == TvDeviceLoginPhase.expired
                  ? 'QR login expired. Generate a new code.'
                  : state.phase == TvDeviceLoginPhase.failed
                      ? (state.message ?? 'Could not start QR login.')
                      : waiting
                          ? 'Waiting for approval on your phone…'
                          : 'Preparing QR login…',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: state.phase == TvDeviceLoginPhase.failed || state.phase == TvDeviceLoginPhase.expired
                ? Theme.of(context).colorScheme.error
                : const Color(0xFF9BA69C),
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 26),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton(
              autofocus: state.phase == TvDeviceLoginPhase.failed || state.phase == TvDeviceLoginPhase.expired,
              onPressed: state.phase == TvDeviceLoginPhase.starting || state.phase == TvDeviceLoginPhase.signingIn ? null : onRefresh,
              child: Text(waiting ? 'Refresh code' : 'Try again'),
            ),
            if (waiting) ...[
              const SizedBox(width: 12),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
            ],
          ],
        ),
      ],
    );
  }
}

class _TvSignedInPane extends StatefulWidget {
  const _TvSignedInPane({
    required this.email,
    required this.busy,
    required this.syncing,
    required this.onSync,
    required this.onSignOut,
  });

  final String email;
  final bool busy;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onSignOut;

  @override
  State<_TvSignedInPane> createState() => _TvSignedInPaneState();
}

class _TvSignedInPaneState extends State<_TvSignedInPane> {
  final _syncFocusNode = FocusNode(debugLabel: 'tv-linear-account-sync');
  final _signOutFocusNode = FocusNode(debugLabel: 'tv-linear-account-sign-out');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _syncFocusNode.canRequestFocus) {
        _syncFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _syncFocusNode.dispose();
    _signOutFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_rounded, color: Color(0xFFB9FF45), size: 64),
        const SizedBox(height: 18),
        const Text('Account connected', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(widget.email, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9BA69C))),
        const SizedBox(height: 28),
        FilledButton.icon(
          focusNode: _syncFocusNode,
          autofocus: true,
          onPressed: widget.busy ? null : widget.onSync,
          icon: widget.syncing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync_rounded),
          label: Text(widget.syncing ? 'Syncing…' : 'Sync now'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          focusNode: _signOutFocusNode,
          onPressed: widget.busy ? null : widget.onSignOut,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _OrvixTvQrScannerScreen extends StatefulWidget {
  const _OrvixTvQrScannerScreen();

  @override
  State<_OrvixTvQrScannerScreen> createState() =>
      _OrvixTvQrScannerScreenState();
}

class _OrvixTvQrScannerScreenState extends State<_OrvixTvQrScannerScreen>
    with WidgetsBindingObserver {
  MobileScannerController _scannerController =
      MobileScannerController(autoStart: false);
  int _scannerGeneration = 0;
  bool _handled = false;
  bool _cameraStarting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startCamera());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_scannerController.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startCamera());
        break;
      case AppLifecycleState.inactive:
        unawaited(_stopCamera());
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _startCamera() async {
    if (!mounted || _cameraStarting || _scannerController.value.isRunning) {
      return;
    }
    _cameraStarting = true;
    try {
      await _scannerController.start();
    } on MobileScannerException {
      // MobileScanner's errorBuilder below owns the visible recovery UI.
    } finally {
      _cameraStarting = false;
    }
  }

  Future<void> _stopCamera() async {
    if (!_scannerController.value.isRunning) return;
    try {
      await _scannerController.stop();
    } on MobileScannerException {
      // The scanner can already be stopping during an Android lifecycle change.
    }
  }

  Future<void> _retryCamera() async {
    final previous = _scannerController;
    try {
      if (previous.value.isRunning) await previous.stop();
    } on MobileScannerException {
      // Replacing the controller below is the recovery path.
    }
    try {
      await previous.dispose();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _scannerController = MobileScannerController(autoStart: false);
      _scannerGeneration++;
      _handled = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  bool _isValidCode(String value) {
    if (value.length != 6) return false;
    return value.codeUnits.every((unit) =>
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90));
  }

  String? _normalizeCode(String raw) {
    final uri = Uri.tryParse(raw.trim());
    final fromUrl = uri?.queryParameters['code'];
    final normalized = (fromUrl ?? raw)
        .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
        .toUpperCase();
    return _isValidCode(normalized) ? normalized : null;
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty || _normalizeCode(value) == null) {
        continue;
      }
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  Future<void> _enterTvCode() async {
    final controller = TextEditingController();
    String? error;
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Enter TV login code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter the 6-character code shown below the QR code on your TV.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 7,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'TV code',
                  hintText: 'ABC-123',
                  errorText: error,
                  counterText: '',
                ),
                onSubmitted: (value) {
                  final normalized = _normalizeCode(value);
                  if (normalized == null) {
                    setDialogState(() => error = 'Enter the 6-character TV code.');
                    return;
                  }
                  Navigator.pop(dialogContext, normalized);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final normalized = _normalizeCode(controller.text);
                if (normalized == null) {
                  setDialogState(() => error = 'Enter the 6-character TV code.');
                  return;
                }
                Navigator.pop(dialogContext, normalized);
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (code != null && mounted && !_handled) {
      _handled = true;
      Navigator.of(context).pop(code);
    }
  }

  Widget _cameraError(
    BuildContext context,
    MobileScannerException error,
    Widget? child,
  ) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 34),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                color: Color(0xFFCBFF75),
                size: 48,
              ),
              const SizedBox(height: 14),
              const Text(
                'Could not start the camera scanner.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Allow Camera permission for Orvix, then retry. You can also enter the TV code manually.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFB7BDB8), height: 1.4),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _retryCamera,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry camera'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _enterTvCode,
                    icon: const Icon(Icons.dialpad_rounded),
                    label: const Text('Enter TV code'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scan Orvix TV QR'),
        actions: [
          TextButton(
            onPressed: _enterTvCode,
            child: const Text('Enter code'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            key: ValueKey('orvix-tv-qr-scanner-$_scannerGeneration'),
            controller: _scannerController,
            errorBuilder: _cameraError,
            onDetect: _handleCapture,
          ),
          Center(
            child: IgnorePointer(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border:
                      Border.all(color: const Color(0xFFB9FF45), width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 42,
            child: Text(
              'Point the camera at the QR code shown by Orvix on your TV.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

