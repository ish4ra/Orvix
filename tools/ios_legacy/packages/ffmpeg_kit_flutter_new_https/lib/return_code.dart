// Mirrors ffmpeg_kit_flutter_new_https 2.6.x. See README.md.
class ReturnCode {
  static const int success = 0;
  static const int cancel = 255;

  final int _value;

  ReturnCode(this._value);

  static bool isSuccess(ReturnCode? returnCode) =>
      returnCode?.getValue() == ReturnCode.success;

  static bool isCancel(ReturnCode? returnCode) =>
      returnCode?.getValue() == ReturnCode.cancel;

  int getValue() => _value;

  bool isValueSuccess() => _value == ReturnCode.success;

  bool isValueError() => _value != ReturnCode.success && _value != ReturnCode.cancel;

  bool isValueCancel() => _value == ReturnCode.cancel;

  @override
  String toString() => _value.toString();
}
