class SpeedCalculator {
  int _prevUpload = 0;
  int _prevDownload = 0;
  DateTime _lastTick = DateTime.now();

  // When true the next update() call only establishes a baseline and does
  // not compute a speed.  This prevents a huge spike after the app returns
  // from the background: cumulative VPN bytes would otherwise be divided
  // by a very short delta-time, yielding absurd values like 190 000 MB/s.
  bool _needsBaseline = true;

  double uploadSpeed = 0;
  double downloadSpeed = 0;

  /// EMA smoothing factor (0.0 - 1.0)
  final double smoothing;

  SpeedCalculator({this.smoothing = 0.2});

  void update({
    required int totalUploadBytes,
    required int totalDownloadBytes,
  }) {
    final now = DateTime.now();

    if (_needsBaseline) {
      // First call after a reset: just record the current counters so the
      // *next* tick has a meaningful baseline to diff against.
      _prevUpload = totalUploadBytes;
      _prevDownload = totalDownloadBytes;
      _lastTick = now;
      _needsBaseline = false;
      return;
    }

    final seconds = now.difference(_lastTick).inMilliseconds / 1000;

    if (seconds <= 0) return;

    final uploadDelta = totalUploadBytes - _prevUpload;
    final downloadDelta = totalDownloadBytes - _prevDownload;

    final rawUpload = uploadDelta / seconds;
    final rawDownload = downloadDelta / seconds;

    // EMA smoothing (чтобы не дёргалось)
    uploadSpeed = (rawUpload * smoothing) + (uploadSpeed * (1 - smoothing));
    downloadSpeed =
        (rawDownload * smoothing) + (downloadSpeed * (1 - smoothing));

    _prevUpload = totalUploadBytes;
    _prevDownload = totalDownloadBytes;
    _lastTick = now;
  }

  void reset() {
    _prevUpload = 0;
    _prevDownload = 0;
    uploadSpeed = 0;
    downloadSpeed = 0;
    _lastTick = DateTime.now();
    _needsBaseline = true;
  }
}