import 'package:file_picker/file_picker.dart';

/// Subtitle file types the player can load from a picked file.
const externalSubtitleExtensions = <String>['srt', 'ass', 'ssa', 'vtt'];

/// Asks the user for one external subtitle file and returns its path, or
/// null when nothing usable was picked.
///
/// Legacy iOS copy of `lib/services/subtitle_file_picker.dart`, written for
/// file_picker 11 (`FilePicker.pickFiles`). Only
/// tools/build_ios_legacy_ipa.sh copies it over the normal file.
Future<String?> pickExternalSubtitlePath() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: externalSubtitleExtensions,
  );
  final files = result?.files;
  if (files == null || files.isEmpty) return null;
  return files.first.path;
}
