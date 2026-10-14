import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/update_prompt_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  late MemoryUpdatePromptStore store;
  late UpdatePromptPolicy policy;

  setUp(() {
    now = DateTime.utc(2026, 10, 14, 12);
    store = MemoryUpdatePromptStore();
    policy = UpdatePromptPolicy(store: store, clock: () => now);
  });

  test('a newer stable prompts when nothing was dismissed', () async {
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isTrue);
  });

  test('betas never prompt automatically', () async {
    expect(await policy.shouldPrompt('0.7.10-beta.4', prerelease: true),
        isFalse);
    expect(await policy.shouldPrompt('0.7.10-beta.999', prerelease: false),
        isFalse, reason: 'the version alone marks it as a beta');
    expect(await policy.shouldPrompt('0.7.11', prerelease: true), isFalse,
        reason: 'GitHub marked it as a prerelease');
  });

  test('Later silences that version during the cooldown only', () async {
    await policy.recordDismissal('0.7.10');
    now = now.add(const Duration(hours: 1));
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isFalse);
    now = now.add(const Duration(hours: 22, minutes: 59));
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isFalse);
    now = now.add(const Duration(minutes: 1));
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isTrue,
        reason: 'the cooldown is over');
  });

  test('a newer stable overrides an older dismissal', () async {
    await policy.recordDismissal('0.7.10');
    expect(await policy.shouldPrompt('0.7.11', prerelease: false), isTrue);
  });

  test('a dismissed beta never silences a stable release', () async {
    await policy.recordDismissal('0.7.10-beta.4');
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isTrue);
  });

  test('build metadata does not create a new version', () async {
    await policy.recordDismissal('0.7.10+4300');
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isFalse);
  });

  test('installing the dismissed version (or newer) clears the dismissal',
      () async {
    await policy.recordDismissal('0.7.10');
    await policy.clearObsolete('0.7.10-beta.3');
    expect(store.value, isNotNull, reason: 'still below the dismissed version');
    await policy.clearObsolete('0.7.10');
    expect(store.value, isNull);
  });

  test('a clock moved backwards cannot silence prompts for long', () async {
    store.value = (version: '0.7.10', at: now.add(const Duration(days: 30)));
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isTrue);
    store.value = (version: '0.7.10', at: now.add(const Duration(hours: 2)));
    expect(await policy.shouldPrompt('0.7.10', prerelease: false), isFalse);
  });

  test('a broken store never blocks the prompt', () async {
    final broken = UpdatePromptPolicy(store: _ThrowingStore(), clock: () => now);
    expect(await broken.shouldPrompt('0.7.10', prerelease: false), isTrue);
    await broken.recordDismissal('0.7.10');
    await broken.clearObsolete('0.7.10');
  });

  test('the default store persists across policy instances', () async {
    SharedPreferences.setMockInitialValues({});
    final first = UpdatePromptPolicy(clock: () => now);
    await first.recordDismissal('0.7.10');
    final second = UpdatePromptPolicy(clock: () => now);
    expect(await second.shouldPrompt('0.7.10', prerelease: false), isFalse);
    expect(await second.shouldPrompt('0.7.11', prerelease: false), isTrue);
  });
}

class _ThrowingStore implements UpdatePromptStore {
  @override
  Future<void> clear() => throw StateError('x');

  @override
  Future<({String version, DateTime at})?> read() => throw StateError('x');

  @override
  Future<void> write(String version, DateTime at) => throw StateError('x');
}
