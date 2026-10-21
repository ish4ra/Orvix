import 'dart:io';

/// The orvix-admin Edge Function's source (modules and dashboard page,
/// without its Deno tests), for tests that check what it exposes.
String orvixAdminSource() {
  final dir = Directory('supabase/functions/orvix-admin');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) =>
          (f.path.endsWith('.ts') && !f.path.endsWith('_test.ts')) ||
          f.path.endsWith('.html'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((f) => f.readAsStringSync()).join('\n');
}
