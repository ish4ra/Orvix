// The credential RPC is not in this repository, so the client reads every
// shape PostgREST can return for it. Placeholder values only.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/supabase_orvix_account_backend.dart';

void main() {
  const set = {'orvix_torbox_api_token_v1': 'test-torbox-token'};
  final parse = SupabaseOrvixAccountBackend.parseCredentialPayload;

  test('a JSON object (returns jsonb)', () {
    expect(parse(Map<String, dynamic>.from(set)), set);
  });

  test('JSON text (returns text) is no longer read as empty', () {
    expect(parse(jsonEncode(set)), set);
    expect(parse('  ${jsonEncode(set)}  '), set);
  });

  test('a one-row set or a wrapping column', () {
    expect(parse([set]), set);
    expect(parse({'payload': jsonEncode(set)}), set);
    expect(parse([
      {'load_orvix_credentials': set}
    ]), set);
  });

  test('nothing stored or unreadable means no credentials', () {
    expect(parse(null), isEmpty);
    expect(parse(''), isEmpty);
    expect(parse('{}'), isEmpty);
    expect(parse('not json'), isEmpty);
    expect(parse(42), isEmpty);
    expect(parse([set, set]), isEmpty);
  });

  test('null values become empty (the sync skips them); others become text',
      () {
    expect(
      parse({'a': null, 'b': 'x', 'c': 7, 'd': true}),
      {'a': '', 'b': 'x', 'c': '7', 'd': 'true'},
    );
  });
}
