import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/ai_sinhala_runtime_state.dart';

void main() {
  test('AI runtime mode derives one coherent set of flags', () {
    const native = AiSinhalaRuntimeState.native();
    expect(native.requested, isFalse);
    expect(native.enabled, isFalse);
    expect(native.liveEmbedded, isFalse);
    expect(native.loading, isFalse);
    expect(native.nativeTextVisible, isTrue);

    const preparing =
        AiSinhalaRuntimeState(AiSinhalaRuntimeMode.preparing);
    expect(preparing.requested, isTrue);
    expect(preparing.enabled, isFalse);
    expect(preparing.liveEmbedded, isFalse);
    expect(preparing.loading, isTrue);
    expect(preparing.nativeTextVisible, isFalse);

    const prepared =
        AiSinhalaRuntimeState(AiSinhalaRuntimeMode.prepared);
    expect(prepared.requested, isTrue);
    expect(prepared.enabled, isTrue);
    expect(prepared.liveEmbedded, isFalse);
    expect(prepared.loading, isFalse);
    expect(prepared.nativeTextVisible, isFalse);

    const live =
        AiSinhalaRuntimeState(AiSinhalaRuntimeMode.liveEmbedded);
    expect(live.requested, isTrue);
    expect(live.enabled, isTrue);
    expect(live.liveEmbedded, isTrue);
    expect(live.loading, isFalse);
    expect(live.nativeTextVisible, isFalse);
  });

  test('preflight can reach every supported success/fallback state', () {
    var state = const AiSinhalaRuntimeState.native();

    state = state.transition(AiSinhalaRuntimeMode.preparing);
    expect(state.mode, AiSinhalaRuntimeMode.preparing);

    state = state.transition(AiSinhalaRuntimeMode.prepared);
    expect(state.mode, AiSinhalaRuntimeMode.prepared);

    state = state.transition(AiSinhalaRuntimeMode.liveEmbedded);
    expect(state.mode, AiSinhalaRuntimeMode.liveEmbedded);

    state = state.transition(AiSinhalaRuntimeMode.native);
    expect(state.mode, AiSinhalaRuntimeMode.native);
  });

  test('native can enable an already prepared subtitle directly', () {
    final state = const AiSinhalaRuntimeState.native()
        .transition(AiSinhalaRuntimeMode.prepared);
    expect(state.mode, AiSinhalaRuntimeMode.prepared);
  });

  test('live fallback is not directly reachable from native', () {
    expect(
      AiSinhalaRuntimeState.canTransition(
        AiSinhalaRuntimeMode.native,
        AiSinhalaRuntimeMode.liveEmbedded,
      ),
      isFalse,
    );
    expect(
      AiSinhalaRuntimeState.canTransition(
        AiSinhalaRuntimeMode.preparing,
        AiSinhalaRuntimeMode.liveEmbedded,
      ),
      isTrue,
    );
    expect(
      AiSinhalaRuntimeState.canTransition(
        AiSinhalaRuntimeMode.prepared,
        AiSinhalaRuntimeMode.liveEmbedded,
      ),
      isTrue,
    );
  });
}
