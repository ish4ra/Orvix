// Mirrors ffmpeg_kit_flutter_new_https 2.6.x. See README.md.
class Log {
  final int _sessionId;
  final int _level;
  final String _message;

  Log(this._sessionId, this._level, this._message);

  int getSessionId() => _sessionId;

  int getLevel() => _level;

  String getMessage() => _message;
}
