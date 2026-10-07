import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/orvix_account_backend.dart';
import '../services/orvix_account_service.dart';
import '../services/platform_profile.dart';
import '../services/tv_device_login_service.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';

/// Steps of the in-app forgot-password flow.
enum _RecoveryStep { email, code, newPassword, done }

/// Steps of the signed-in change-password flow. [code] is only used when the
/// backend asks the user to confirm a security code first.
enum _ChangePasswordStep { newPassword, code, done }

/// Widest the non-TV Account title, form and "What syncs" column may grow.
const double accountContentMaxWidth = 720;

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.onAuthChanged,
    this.active = true,
  });

  final VoidCallback onAuthChanged;

  /// Whether Account is the visible destination. On Android TV the QR login
  /// only runs while it is.
  final bool active;

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
  final _deleteConfirm = TextEditingController();
  final _deletePassword = TextEditingController();

  bool _busy = false;
  bool _syncing = false;
  bool _approvingTv = false;
  bool _signUp = false;
  String? _message;
  String? _pendingVerificationEmail;
  Timer? _resendTimer;
  int _resendSeconds = 0;
  _RecoveryStep? _recoveryStep;
  String? _recoveryEmail;
  _ChangePasswordStep? _changeStep;
  String? _changeUserId;
  String? _deleteUserId;
  TvDeviceLoginController? _tvLogin;
  bool _tvSignInReported = false;

  /// Sync now ran after the current TV login, so its sync warning is stale.
  bool _tvLoginSyncRetried = false;

  @override
  void initState() {
    super.initState();
    if (PlatformProfile.isAndroidTv) {
      _tvLogin = TvDeviceLoginController()..addListener(_handleTvLoginChange);
      if (widget.active && OrvixAccountService.currentUser == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _startTvLogin());
      }
    }
  }

  @override
  void didUpdateWidget(covariant AccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final login = _tvLogin;
    if (login == null || widget.active == oldWidget.active) return;
    if (!widget.active) {
      // Leaving Account: stop polling; the code shown so far stops working.
      if (!login.state.busy) login.cancel();
    } else if (OrvixAccountService.currentUser == null &&
        !login.state.busy &&
        !login.state.showsCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startTvLogin());
    }
  }

  void _startTvLogin() {
    final login = _tvLogin;
    if (!mounted || login == null) return;
    _tvSignInReported = false;
    _tvLoginSyncRetried = false;
    unawaited(login.start());
  }

  void _handleTvLoginChange() {
    if (!mounted) return;
    final state = _tvLogin!.state;
    setState(() {});
    if (state.signedIn && !_tvSignInReported) {
      _tvSignInReported = true;
      widget.onAuthChanged();
    }
  }

  @override
  void dispose() {
    _tvLogin?.removeListener(_handleTvLoginChange);
    _tvLogin?.dispose();
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
    _deleteConfirm.dispose();
    _deletePassword.dispose();
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
          setState(() => _message = _afterSignInMessage(
              response.sync,
              'Account created and your local Orvix data was synced.',
              'Account created.'));
          widget.onAuthChanged();
        }
      } else {
        final response =
            await OrvixAccountService.signIn(email: email, password: password);
        if (!mounted) return;
        _password.clear();
        setState(() => _message = _afterSignInMessage(
            response.sync,
            'Signed in. Your local and cloud Orvix data were merged.',
            'Signed in.'));
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
      var response = await OrvixAccountService.verifySignupOtp(
        email: email,
        token: code,
      );
      if (!response.hasSession) {
        response = await OrvixAccountService.signIn(
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
        _message = _afterSignInMessage(
            response.sync,
            'Email verified. Your Orvix account is ready and cloud sync is active.',
            'Email verified. Your Orvix account is ready.');
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
      case OrvixAuthErrorKind.invalidCredentials:
      case OrvixAuthErrorKind.accountChanged:
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
      case OrvixAuthErrorKind.invalidCredentials:
      case OrvixAuthErrorKind.accountChanged:
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

  /// The word typed to confirm account deletion.
  static const _deleteConfirmation = 'DELETE';

  String _friendlyDeleteAccountMessage(OrvixAuthException error) {
    switch (error.kind) {
      case OrvixAuthErrorKind.invalidCredentials:
        return 'That password is not correct. Your account was not deleted.';
      case OrvixAuthErrorKind.network:
        return 'Could not reach Orvix Cloud, so your account was not deleted. Check your internet connection and try again.';
      case OrvixAuthErrorKind.rateLimited:
        final seconds = error.retryAfterSeconds;
        return seconds == null
            ? 'Too many attempts. Please wait a minute and try again.'
            : 'Too many attempts. Please wait $seconds seconds and try again.';
      case OrvixAuthErrorKind.sessionMissing:
        return 'Your sign-in has expired. Sign out, sign in again, then delete your account.';
      case OrvixAuthErrorKind.reauthenticationRequired:
        return 'For your security, enter your current password again to delete your account.';
      case OrvixAuthErrorKind.accountChanged:
        return 'The signed-in account changed, so nothing was deleted. Check which account you are signed in to and try again.';
      case OrvixAuthErrorKind.invalidCode:
      case OrvixAuthErrorKind.invalidEmail:
      case OrvixAuthErrorKind.weakPassword:
      case OrvixAuthErrorKind.samePassword:
      case OrvixAuthErrorKind.unknown:
        return 'Could not delete your account right now, so it was not deleted. Please try again later.';
    }
  }

  void _clearDeleteAccountState() {
    _deleteUserId = null;
    _deleteConfirm.clear();
    _deletePassword.clear();
  }

  void _startDeleteAccount(OrvixAccountUser user) {
    setState(() {
      _clearChangePasswordState();
      _clearDeleteAccountState();
      _deleteUserId = user.id;
      _message = null;
    });
  }

  void _closeDeleteAccount() {
    setState(() {
      _clearDeleteAccountState();
      _message = null;
    });
  }

  bool get _deleteAccountConfirmed =>
      _deleteConfirm.text.trim() == _deleteConfirmation &&
      _deletePassword.text.isNotEmpty;

  Future<void> _submitDeleteAccount() async {
    if (_busy) return;
    final user = OrvixAccountService.currentUser;
    if (user == null || user.id != _deleteUserId) {
      setState(() {
        _clearDeleteAccountState();
        _message =
            'You are no longer signed in to that account, so nothing was deleted.';
      });
      return;
    }
    if (_deleteConfirm.text.trim() != _deleteConfirmation) {
      setState(() => _message =
          'Type $_deleteConfirmation to confirm that you want to delete your account.');
      return;
    }
    final password = _deletePassword.text;
    if (password.isEmpty) {
      setState(() => _message = 'Enter your current password.');
      return;
    }
    // The password only lives in this call; it is never kept in state.
    _deletePassword.clear();
    setState(() {
      _busy = true;
      _message = 'Deleting your Orvix account…';
    });

    try {
      await OrvixAccountService.deleteAccount(currentPassword: password);
      if (!mounted) return;
      setState(() {
        _clearDeleteAccountState();
        _message =
            'Your Orvix account was permanently deleted. Orvix keeps working on this device without an account, and the library, progress and settings on this device are still here.';
      });
      widget.onAuthChanged();
    } on OrvixAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        if (OrvixAccountService.currentUser?.id != _deleteUserId) {
          _clearDeleteAccountState();
        }
        _message = _friendlyDeleteAccountMessage(error);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not delete your account right now, so it was not deleted. Please try again later.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The message after signing in. Signing in worked even when the sync
  /// that followed did not, so a sync problem is a warning, never an error.
  static String _afterSignInMessage(
      OrvixSyncResult? sync, String synced, String signedIn) {
    final problem = sync?.problem;
    if (problem == null) return synced;
    return '$signedIn $problem Use Sync now to try again.';
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _busy = true;
      _syncing = true;
      _tvLoginSyncRetried = true;
      _message = 'Syncing your Orvix data…';
    });
    try {
      final result = await OrvixAccountService.mergeCloudIntoLocal()
          .timeout(const Duration(seconds: 20));
      if (mounted) {
        final now = DateTime.now();
        final minute = now.minute.toString().padLeft(2, '0');
        final problem = result.problem;
        setState(() => _message = problem == null
            ? 'Sync complete • ${now.hour}:$minute'
            : '$problem Your data on this device is safe; try again later.');
        // Whatever did sync (a restored provider, merged library) shows now.
        widget.onAuthChanged();
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _message =
              'Cloud sync timed out after 20 seconds. Your local data is safe; try again when the connection is stable.';
        });
      }
    } catch (_) {
      // No backend detail is shown: it may echo request data.
      if (mounted) {
        setState(() => _message =
            'Sync failed. Your data on this device is safe; try again later.');
      }
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
      if (PlatformProfile.isAndroidTv && widget.active) _startTvLogin();
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
        // A vertical ListView gives its children a tight cross-axis width, so
        // a bare ConstrainedBox here would still stretch to the full content
        // area. Align loosens that constraint so the 720px cap actually holds
        // on wide windows; the SizedBox then fills up to that cap, so the card
        // keeps one width in every account state and still shrinks to fit
        // narrower windows.
        Align(
          alignment: AlignmentDirectional.topStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: accountContentMaxWidth),
            child: SizedBox(
              width: double.infinity,
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
                            : _deleteUserId == user.id
                                ? _deleteAccountForm(user)
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
          ),
        ),
      ],
    );
  }

  Widget _buildTvAccount(BuildContext context, OrvixAccountUser? user) {
    final login = _tvLogin!;
    return _TvAccountView(
      user: user,
      login: login.state,
      busy: _busy,
      syncing: _syncing || login.state.phase == TvDeviceLoginPhase.syncing,
      message: login.state.phase == TvDeviceLoginPhase.syncFailed &&
              !_tvLoginSyncRetried
          ? login.state.message
          : _message,
      onNewCode: _startTvLogin,
      onCancel: login.cancel,
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

  Widget _deleteAccountForm(OrvixAccountUser user) {
    final colors = Theme.of(context).colorScheme;
    final email = user.email ?? 'this account';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _recoveryHeader(Icons.warning_amber_rounded, 'Delete account'),
        const SizedBox(height: 10),
        _recoveryHint(
            'This permanently deletes the Orvix account $email. It cannot be undone. Deleting it removes:'),
        const SizedBox(height: 8),
        for (final line in const [
          'Your Orvix account and its sign-in',
          'Your cloud-synced library, watchlist, Continue Watching progress and preferences',
          'Debrid and cloud-service credentials synced to your account (stored encrypted)',
          'TV sign-ins and TV login codes linked to this account',
        ])
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: _recoveryHint('•  $line'),
          ),
        const SizedBox(height: 8),
        _recoveryHint(
            'Orvix data on this device is not erased. Your library, watchlist, progress, settings and the service connections saved on this device stay here, and Orvix keeps working without an account. Other devices signed in to this account will be signed out.'),
        const SizedBox(height: 16),
        TextField(
          controller: _deleteConfirm,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
              labelText: 'Type $_deleteConfirmation to confirm'),
        ),
        const SizedBox(height: 12),
        _PasswordField(
          controller: _deletePassword,
          enabled: !_busy,
          label: 'Current password',
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) =>
              _busy || !_deleteAccountConfirmed ? null : _submitDeleteAccount(),
        ),
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: Listenable.merge([_deleteConfirm, _deletePassword]),
          builder: (context, _) => Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                ),
                onPressed: _busy || !_deleteAccountConfirmed
                    ? null
                    : _submitDeleteAccount,
                icon: _busyIcon(Icons.delete_forever_rounded),
                label: const Text('Delete permanently'),
              ),
              TextButton(
                onPressed: _busy ? null : _closeDeleteAccount,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _approveTvCode(String code) async {
    if (_approvingTv) return;
    if (OrvixAccountService.currentUser == null) {
      setState(() => _message = TvDeviceLoginService.approvalMessage(
          TvApprovalResult.notSignedIn));
      return;
    }
    if (TvDeviceLoginService.normalizeCode(code) == null) {
      setState(() => _message = TvDeviceLoginService.approvalMessage(
          TvApprovalResult.invalidCode));
      return;
    }
    // Approving signs the TV in to this account, so make sure the code on
    // screen belongs to the user's own TV (a QR code can come from anywhere).
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign in on this TV?'),
        content: Text(
          'Orvix on the TV showing ${TvDeviceLoginService.displayCode(code)} will be signed in to your account. Only approve a TV you own.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _approvingTv) return;
    setState(() {
      _approvingTv = true;
      _busy = true;
      _message = 'Approving TV…';
    });
    try {
      final result = await TvDeviceLoginService.approveScanned(code);
      if (mounted) {
        setState(() => _message = TvDeviceLoginService.approvalMessage(result));
      }
    } finally {
      _approvingTv = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanTvQr() async {
    if (!Platform.isAndroid || PlatformProfile.isAndroidTv || _busy) return;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _OrvixTvQrScannerScreen()),
    );
    if (code != null && mounted) await _approveTvCode(code);
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
        // Account deletion is managed from phones and desktops; Android TV
        // stays QR/device-login only.
        if (!PlatformProfile.isAndroidTv) ...[
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text('Delete account',
              style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 6),
          _recoveryHint(
              'Permanently delete your Orvix account and its cloud data. Data on this device stays.'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(color: Theme.of(context).colorScheme.error),
            ),
            onPressed: _busy ? null : () => _startDeleteAccount(user),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete account'),
          ),
        ],
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


/// Android TV Account: QR sign-in when signed out, sync and sign-out when
/// signed in. Password management stays on phones and desktops.
class _TvAccountView extends StatefulWidget {
  const _TvAccountView({
    required this.user,
    required this.login,
    required this.busy,
    required this.syncing,
    required this.message,
    required this.onNewCode,
    required this.onCancel,
    required this.onSync,
    required this.onSignOut,
  });

  final OrvixAccountUser? user;
  final TvDeviceLoginState login;
  final bool busy;
  final bool syncing;
  final String? message;
  final VoidCallback onNewCode;
  final VoidCallback onCancel;
  final VoidCallback onSync;
  final VoidCallback onSignOut;

  @override
  State<_TvAccountView> createState() => _TvAccountViewState();
}

class _TvAccountViewState extends State<_TvAccountView> {
  // Kept for the life of the screen so focus stays on the same action while
  // the login moves between states.
  final _primaryAction = FocusNode(debugLabel: 'tv-account-primary');
  final _cancelAction = FocusNode(debugLabel: 'tv-account-cancel');
  final _syncAction = FocusNode(debugLabel: 'tv-account-sync');
  final _signOutAction = FocusNode(debugLabel: 'tv-account-sign-out');

  @override
  void dispose() {
    _primaryAction.dispose();
    _cancelAction.dispose();
    _syncAction.dispose();
    _signOutAction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final intro = _TvAccountIntro(signedIn: user != null);
        final panel = user == null ? _qrPanel() : _signedInPanel(user);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            TvMetrics.pageHorizontal,
            TvMetrics.pageTop,
            TvMetrics.pageHorizontal,
            TvMetrics.pageBottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - TvMetrics.pageTop - TvMetrics.pageBottom,
            ),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [intro, const SizedBox(height: 24), panel],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: intro),
                      const SizedBox(width: 40),
                      SizedBox(width: 400, child: panel),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _panel({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: TvColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: TvColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      );

  Widget _qrPanel() {
    final state = widget.login;
    final phase = state.phase;
    final url = state.verificationUrl;
    final code = state.userCode;
    final (IconData statusIcon, Color statusColor, String status) =
        switch (phase) {
      TvDeviceLoginPhase.idle => (
          Icons.pause_circle_outline_rounded,
          TvColors.textMuted,
          'Sign-in code stopped.',
        ),
      TvDeviceLoginPhase.preparing => (
          Icons.hourglass_top_rounded,
          TvColors.textMuted,
          'Preparing a sign-in code…',
        ),
      TvDeviceLoginPhase.waiting => (
          Icons.phone_android_rounded,
          TvColors.lime,
          'Waiting for approval on your phone…',
        ),
      TvDeviceLoginPhase.connectionIssue => (
          Icons.wifi_off_rounded,
          TvColors.danger,
          state.message ?? 'Connection problem. Retrying…',
        ),
      TvDeviceLoginPhase.signingIn => (
          Icons.verified_rounded,
          TvColors.lime,
          state.message ?? 'Approved. Signing in…',
        ),
      TvDeviceLoginPhase.syncing ||
      TvDeviceLoginPhase.signedIn ||
      TvDeviceLoginPhase.syncFailed =>
        (Icons.check_circle_rounded, TvColors.lime, 'Signed in.'),
      TvDeviceLoginPhase.expired ||
      TvDeviceLoginPhase.rejected ||
      TvDeviceLoginPhase.failed =>
        (
          Icons.error_outline_rounded,
          TvColors.danger,
          state.message ?? 'Could not sign in. Generate a new code.',
        ),
    };
    final showQr = state.showsCode && url != null;
    final working = phase == TvDeviceLoginPhase.preparing ||
        phase == TvDeviceLoginPhase.signingIn;
    final canCancel = phase == TvDeviceLoginPhase.preparing ||
        phase == TvDeviceLoginPhase.waiting ||
        phase == TvDeviceLoginPhase.connectionIssue;

    return _panel(children: [
      Container(
        key: const ValueKey('tv-account-qr'),
        width: 212,
        height: 212,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: showQr ? Colors.white : TvColors.card,
          borderRadius: BorderRadius.circular(16),
          border: showQr ? null : Border.all(color: TvColors.border),
        ),
        child: showQr
            ? QrImageView(
                data: url,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
              )
            : Center(
                child: working
                    ? const CircularProgressIndicator(color: TvColors.primary)
                    : Icon(Icons.qr_code_2_rounded,
                        size: 84,
                        color: state.needsNewCode
                            ? TvColors.textDim
                            : TvColors.borderStrong),
              ),
      ),
      const SizedBox(height: 18),
      SizedBox(
        height: 40,
        child: code != null && (showQr || phase == TvDeviceLoginPhase.signingIn)
            ? Text(
                TvDeviceLoginService.displayCode(code),
                key: const ValueKey('tv-account-code'),
                style: const TextStyle(
                  color: TvColors.text,
                  fontSize: 32,
                  letterSpacing: 5,
                  fontWeight: FontWeight.w900,
                ),
              )
            : null,
      ),
      const SizedBox(height: 10),
      Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(statusIcon, size: 18, color: statusColor),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              status,
              key: const ValueKey('tv-account-status'),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TvText.caption.copyWith(color: statusColor, fontSize: 13.5),
            ),
          ),
        ],
      ),
      const SizedBox(height: 22),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvButton(
            key: const ValueKey('tv-account-new-code'),
            expanded: true,
            focusNode: _primaryAction,
            preferred: true,
            kind: state.needsNewCode || phase == TvDeviceLoginPhase.idle
                ? TvButtonKind.primary
                : TvButtonKind.secondary,
            icon: Icons.refresh_rounded,
            label: state.needsNewCode
                ? 'Generate new code'
                : phase == TvDeviceLoginPhase.idle
                    ? 'Show code'
                    : 'Refresh code',
            busy: working,
            onPressed: widget.onNewCode,
          ),
          if (canCancel) ...[
            const SizedBox(height: 12),
            TvButton(
              key: const ValueKey('tv-account-cancel'),
              expanded: true,
              focusNode: _cancelAction,
              kind: TvButtonKind.quiet,
              icon: Icons.close_rounded,
              label: 'Cancel',
              onPressed: widget.onCancel,
            ),
          ],
        ],
      ),
    ]);
  }

  Widget _signedInPanel(OrvixAccountUser user) {
    final message = widget.message;
    return _panel(children: [
      const Icon(Icons.check_circle_rounded, color: TvColors.primary, size: 56),
      const SizedBox(height: 14),
      const Text('Account connected', style: TvText.section),
      const SizedBox(height: 6),
      Text(
        user.email ?? 'Orvix account',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TvText.body.copyWith(color: TvColors.lime),
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvButton(
                key: const ValueKey('tv-account-sync'),
                expanded: true,
                focusNode: _syncAction,
                preferred: true,
                kind: TvButtonKind.primary,
                icon: Icons.sync_rounded,
                label: widget.syncing ? 'Syncing…' : 'Sync now',
                busy: widget.syncing,
                enabled: !widget.busy,
                onPressed: widget.onSync,
              ),
            const SizedBox(height: 12),
            TvButton(
                key: const ValueKey('tv-account-sign-out'),
                expanded: true,
                focusNode: _signOutAction,
                icon: Icons.logout_rounded,
                label: 'Sign out',
                enabled: !widget.busy,
                onPressed: widget.onSignOut,
              ),
          ],
        ),
      ),
      if (message != null) ...[
        const SizedBox(height: 18),
        Text(
          message,
          key: const ValueKey('tv-account-message'),
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TvText.caption.copyWith(fontSize: 13.5),
        ),
      ],
    ]);
  }
}

class _TvAccountIntro extends StatelessWidget {
  const _TvAccountIntro({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/branding/orvix_logo.webp',
          height: 52,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const SizedBox(height: 52),
        ),
        const SizedBox(height: 22),
        Text(
          signedIn ? 'Your Orvix, synced.' : 'Sign in with your phone',
          style: TvText.display,
        ),
        const SizedBox(height: 14),
        Text(
          signedIn
              ? 'Library, Watchlist, Continue Watching and your Orvix preferences sync with this TV.'
              : 'No typing on the TV. Approve this TV from a phone that is signed in to Orvix.',
          style: TvText.body.copyWith(fontSize: 16),
        ),
        if (!signedIn) ...[
          const SizedBox(height: 22),
          const _TvStep(
            number: 1,
            text: 'Scan the QR code with your phone camera, or open Orvix on the phone and choose Account › Scan TV QR.',
          ),
          const _TvStep(
            number: 2,
            text: 'Sign in on the phone if asked, then approve the code shown here.',
          ),
          const _TvStep(
            number: 3,
            text: 'This TV signs in on its own within a few seconds.',
          ),
        ],
      ],
    );
  }
}

class _TvStep extends StatelessWidget {
  const _TvStep({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: TvColors.primary.withValues(alpha: .14),
              shape: BoxShape.circle,
              border: Border.all(color: TvColors.primary.withValues(alpha: .5)),
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: TvColors.lime,
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TvText.body)),
        ],
      ),
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
  final _scanGate = TvQrScanGate();
  bool _manualEntryOpen = false;
  bool _cameraStarting = false;
  bool _showInvalidHint = false;

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
      _scanGate.reset();
      _showInvalidHint = false;
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

  /// Pops the scanner once, with the normalized code. Camera frames often
  /// report the same QR code several times; only the first one counts.
  void _finish(String code) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    unawaited(_stopCamera());
    Navigator.of(context).pop(code);
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_scanGate.accepted || _manualEntryOpen) return;
    var sawValue = false;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      sawValue = true;
      final code = _scanGate.accept(value);
      if (code != null) {
        _finish(code);
        return;
      }
    }
    if (sawValue && !_showInvalidHint && mounted) {
      setState(() => _showInvalidHint = true);
    }
  }

  Future<void> _enterTvCode() async {
    if (_manualEntryOpen || _scanGate.accepted) return;
    _manualEntryOpen = true;
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
                  final normalized = TvDeviceLoginService.normalizeCode(value);
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
                final normalized =
                    TvDeviceLoginService.normalizeCode(controller.text);
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
    _manualEntryOpen = false;
    if (code == null || !mounted) return;
    final accepted = _scanGate.accept(code);
    if (accepted != null) _finish(accepted);
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
          Positioned(
            left: 24,
            right: 24,
            bottom: 42,
            child: Text(
              _showInvalidHint
                  ? 'That QR code is not an Orvix TV code. Point the camera at the QR code shown by Orvix on your TV.'
                  : 'Point the camera at the QR code shown by Orvix on your TV.',
              textAlign: TextAlign.center,
              style: const TextStyle(
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

