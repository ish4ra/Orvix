  final Map<int, int> _bitmapOffsetVotes = <int, int>{};

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _preparedAiSubtitle = widget.aiSubtitle;
    _aiSinhalaEnabled = _preparedAiSubtitle != null;
    _playbackErrorSubscription =
        widget.playback.player.stream.error.listen(_onPlaybackError);
    if (_aiSinhalaEnabled) {
      _positionSubscription =
          widget.playback.player.stream.position.listen(_onPosition);
      _subtitleTimingSubscription =
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
      unawaited(_loadManualSync());
    }
    _open();
    _scheduleHide();
    _saveTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _persistProgress());
    _completedSubscription =
        widget.playback.player.stream.completed.listen((completed) {
      if (completed) _startNextCountdown();
    });
    WidgetsBinding.instance