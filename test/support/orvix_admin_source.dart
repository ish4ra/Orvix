import 'dart:io';

/// The orvix-admin Edge Function's source (modules, the Control Center page
/// and its script in web/, without Deno tests or vendored libraries), for
/// tests that check what it exposes.
String orvixAdminSource() {
  final dir = Directory('supabase/functions/orvix-admin');
  final files = <File>[
    ...dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.ts') && !f.path.endsWith('_test.ts')),
    File('${dir.path}/web/index.html'),
    File('${dir.path}/web/app.js'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return files.map((f) => f.readAsStringSync()).join('\n');
}
