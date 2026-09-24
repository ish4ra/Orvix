enum AiSinhalaRuntimeMode {
  native,
  preparing,
  prepared,
  liveEmbedded,
}

class AiSinhalaRuntimeState {
  const AiSinhalaRuntimeState(this.mode);

  const AiSinhalaRuntimeState.native()
      : mode = AiSinhalaRuntimeMode.native;

  final AiSinhalaRuntimeMode mode;

  bool get requested => mode != AiSinhalaRuntimeMode.native;

  bool get enabled =>
      mode == AiSinhalaRuntimeMode.prepared ||
      mode == AiSinhalaRuntimeMode.liveEmbedded;

  bool get liveEmbedded => mode == AiSinhalaRuntimeMode.liveEmbedded;

  bool get loading => mode == AiSinhalaRuntimeMode.preparing;

  bool get nativeTextVisible => !requested;

  static bool canTransition(
    AiSinhalaRuntimeMode from,
    AiSinhalaRuntimeMode to,
  ) {
    if (from == to) return true;
    return switch (from) {
      AiSinhalaRuntimeMode.native =>
        to == AiSinhalaRuntimeMode.preparing ||
            to == AiSinhalaRuntimeMode.prepared ||
            to == AiSinhalaRuntimeMode.liveEmbedded,
      AiSinhalaRuntimeMode.preparing =>
        to == AiSinhalaRuntimeMode.prepared ||
            to == AiSinhalaRuntimeMode.liveEmbedded ||
            to == AiSinhalaRuntimeMode.native,
      AiSinhalaRuntimeMode.prepared =>
        to == AiSinhalaRuntimeMode.liveEmbedded ||
            to == AiSinhalaRuntimeMode.native,
      AiSinhalaRuntimeMode.liveEmbedded =>
        to == AiSinhalaRuntimeMode.native,
    };
  }

  AiSinhalaRuntimeState transition(AiSinhalaRuntimeMode next) {
    assert(
      canTransition(mode, next),
      'Illegal AI Sinhala state transition: $mode -> $next',
    );
    return AiSinhalaRuntimeState(next);
  }
}
