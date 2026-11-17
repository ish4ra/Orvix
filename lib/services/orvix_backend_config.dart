/// Which Supabase project this build talks to.
///
/// Normal builds use the production project and nothing here changes that.
/// A private test build is compiled with all three of
///
///   --dart-define=ORVIX_TEST_BUILD=true
///   --dart-define=ORVIX_SUPABASE_URL=https://<test project>.supabase.co
///   --dart-define=ORVIX_SUPABASE_PUBLISHABLE_KEY=<test project's public key>
///
/// and then talks only to that project. Anything else is refused at startup,
/// so a build can never pair one project's address with another's key, and a
/// test build can never reach the production project.
///
/// Only public client keys belong here. A secret or service-role key is
/// refused.
library;

import 'dart:convert';

class OrvixBackend {
  const OrvixBackend({
    required this.url,
    required this.publishableKey,
    required this.isTest,
  });

  final String url;
  final String publishableKey;
  final bool isTest;
}

class OrvixBackendConfigError extends Error {
  OrvixBackendConfigError(this.message);

  final String message;

  @override
  String toString() => 'Orvix backend configuration: $message';
}

class OrvixBackendConfig {
  OrvixBackendConfig._();

  static const String productionUrl =
      'https://kpjuisxofwqxhbnnsyzf.supabase.co';
  static const String productionPublishableKey =
      'sb_publishable_HmqvNavX_iovenN3YRgpmA_cgxQdG9y';

  /// True only in a private test build. Compile-time constant, so in normal
  /// builds every `if (isTestBuild)` branch is removed by the compiler.
  static const bool isTestBuild = bool.fromEnvironment('ORVIX_TEST_BUILD');

  static const String _urlOverride = String.fromEnvironment(
    'ORVIX_SUPABASE_URL',
  );
  static const String _keyOverride = String.fromEnvironment(
    'ORVIX_SUPABASE_PUBLISHABLE_KEY',
  );

  /// The project this build uses. Throws [OrvixBackendConfigError] when the
  /// build was compiled with an unsafe or incomplete combination.
  static OrvixBackend get current => resolve(
        testBuild: isTestBuild,
        urlOverride: _urlOverride,
        keyOverride: _keyOverride,
      );

  static OrvixBackend resolve({
    required bool testBuild,
    required String urlOverride,
    required String keyOverride,
  }) {
    final url = urlOverride.trim();
    final key = keyOverride.trim();

    if (!testBuild) {
      if (url.isNotEmpty || key.isNotEmpty) {
        throw OrvixBackendConfigError(
          'a Supabase override was given without ORVIX_TEST_BUILD=true. '
          'Only test builds may use another project.',
        );
      }
      return const OrvixBackend(
        url: productionUrl,
        publishableKey: productionPublishableKey,
        isTest: false,
      );
    }

    if (url.isEmpty || key.isEmpty) {
      throw OrvixBackendConfigError(
        'a test build needs both ORVIX_SUPABASE_URL and '
        'ORVIX_SUPABASE_PUBLISHABLE_KEY.',
      );
    }
    final ref = projectRef(url);
    if (ref == null) {
      throw OrvixBackendConfigError(
        'ORVIX_SUPABASE_URL must look like https://<project>.supabase.co.',
      );
    }
    if (ref == projectRef(productionUrl)) {
      throw OrvixBackendConfigError(
        'a test build must not use the production project.',
      );
    }
    if (key == productionPublishableKey) {
      throw OrvixBackendConfigError(
        'a test build must not use the production key.',
      );
    }
    final keyProblem = publishableKeyProblem(key, ref);
    if (keyProblem != null) throw OrvixBackendConfigError(keyProblem);

    return OrvixBackend(
      url: 'https://$ref.supabase.co',
      publishableKey: key,
      isTest: true,
    );
  }

  static final RegExp _projectUrl = RegExp(
    r'^https://([a-z0-9]{16,32})\.supabase\.co/?$',
  );

  /// The project id in a hosted Supabase address, or null if [url] is not
  /// one.
  static String? projectRef(String url) =>
      _projectUrl.firstMatch(url.trim())?.group(1);

  /// Why [key] must not be shipped in a client for project [ref], or null
  /// when it is a public client key for that project.
  static String? publishableKeyProblem(String key, String ref) {
    if (key.startsWith('sb_secret_')) {
      return 'the key is a secret key. Use the publishable key.';
    }
    if (key.startsWith('sb_publishable_')) {
      return key.length > 'sb_publishable_'.length + 8
          ? null
          : 'the publishable key is incomplete.';
    }
    // Legacy keys are JWTs that name their role and project.
    final parts = key.split('.');
    if (parts.length != 3) {
      return 'the key is not a Supabase publishable or anon key.';
    }
    final Object? claims;
    try {
      claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
    } catch (_) {
      return 'the key is not a Supabase publishable or anon key.';
    }
    if (claims is! Map) {
      return 'the key is not a Supabase publishable or anon key.';
    }
    if (claims['role'] != 'anon') {
      return 'the key is not an anon key. Never ship a service-role key.';
    }
    if (claims['ref'] != ref) {
      return 'the key belongs to a different project than the address.';
    }
    return null;
  }
}
