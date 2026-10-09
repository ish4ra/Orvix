import 'package:file_picker/file_picker.dart';

/// Subtitle file types the player can load from a picked file.
const externalSubtitleExtensions = <String>['srt', 'ass', 'ssa', 'vtt'];

/// Asks the user for one external subtitle file and returns its path, or
/// null when nothing usable was picked.
///
/// The Legacy iOS build swaps in
/// `tools/ios_legacy/overlay/lib/services/subtitle_file_picker.dart`, which
/// makes the same request through file_picker 11, the newest release that
/// still supports iOS 12 and Flutter 3.32. Keep both files' public API equal.
Future<String?> pickExternalSubtitlePath() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: externalSubtitleExtensions,
  );
  return file?.path;
}
