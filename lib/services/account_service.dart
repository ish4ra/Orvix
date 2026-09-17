import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OrvixSupabaseConfig {
  static const url = String.fromEnvironment('ORVIX_SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'ORVIX_SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get configured =>
      url.trim().isNotEmpty && publishableKey.trim().isNotEmpty;
}

class AccountService extends ChangeNotifier {
  AccountService() {
    if (backendConfigured) {
      _authSubscription = client.auth.onAuthStateChange.listen((_) {
        notifyListeners();
      });
    }
  }

  StreamSubscription<AuthState>? _authSubscription;

  static Future<void> initializeBackend() async {
    if (!OrvixSupabaseConfig.configured) return;
    await Supabase.initialize(
      url: OrvixSupabaseConfig.url,
      publishableKey: OrvixSupabaseConfig.publishableKey,
    );
  }

  bool get backendConfigured => OrvixSupabaseConfig.configured;

  SupabaseClient get client {
    if (!backendConfigured) {
      throw StateError('Orvix cloud sync is not configured for this build.');
    }
    return Supabase.instance.client;
  }

  User? get currentUser => backendConfigured ? client.auth.currentUser : null;
  Session? get currentSession => backendConfigured ? client.auth.currentSession : null;
  bool get signedIn => currentUser != null;

  String get displayEmail => currentUser?.email?.trim().isNotEmpty == true
      ? currentUser!.email!.trim()
      : 'Orvix account';

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    if (!backendConfigured) {
      throw StateError('Cloud sync is not configured for this build.');
    }
    final response = await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    notifyListeners();
    return response;
  }

  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    if (!backendConfigured) {
      throw StateError('Cloud sync is not configured for this build.');
    }
    final response = await client.auth.signUp(
      email: email.trim(),
      password: password,
    );
    notifyListeners();
    return response;
  }

  Future<void> signOut() async {
    if (!backendConfigured || !signedIn) return;
    await client.auth.signOut();
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
