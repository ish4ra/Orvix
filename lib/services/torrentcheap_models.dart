// Provider-neutral data models for the experimental TorrentCheap adapter.
//
// TorrentCheap publishes no third-party API. These types describe what Orvix
// needs from the service, not a confirmed wire format: no field here maps to a
// verified JSON key. A future transport (see TorrentCheapGateway) is
// responsible for translating whatever the provider actually returns into
// these models, and must be backed by confirmed schemas and fixtures.
// See docs/TORRENTCHEAP_RESEARCH.md.

/// One file inside a magnet, as offered for selection before a task is made.
class TorrentCheapMagnetFile {
  const TorrentCheapMagnetFile({
    required this.index,
    required this.path,
    required this.sizeBytes,
  });

  /// Position of the file inside the torrent. Used as the selection key.
  final int index;
  final String path;
  final int sizeBytes;

  String get name {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }
}

class TorrentCheapMagnetMetadata {
  const TorrentCheapMagnetMetadata({
    required this.infoHash,
    required this.name,
    required this.files,
  });

  /// Lower-case hex info hash, normalized by the service.
  final String infoHash;
  final String name;
  final List<TorrentCheapMagnetFile> files;

  int get totalBytes => files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
}

enum TorrentCheapTaskState { queued, downloading, completed, failed, unknown }

class TorrentCheapTask {
  const TorrentCheapTask({
    required this.id,
    required this.state,
    this.infoHash,
    this.name,
    this.progress = 0,
    this.sizeBytes,
    this.cloudFolderId,
    this.message,
  });

  final String id;
  final TorrentCheapTaskState state;
  final String? infoHash;
  final String? name;

  /// 0.0 to 1.0.
  final double progress;
  final int? sizeBytes;

  /// Cloud folder that holds the task's files once it completes, if known.
  final String? cloudFolderId;
  final String? message;

  bool get isComplete => state == TorrentCheapTaskState.completed;
  bool get isFailed => state == TorrentCheapTaskState.failed;
  bool get isActive =>
      state == TorrentCheapTaskState.queued ||
      state == TorrentCheapTaskState.downloading;
}

class TorrentCheapCloudEntry {
  const TorrentCheapCloudEntry({
    required this.id,
    required this.name,
    required this.isFolder,
    this.sizeBytes,
    this.parentId,
  });

  final String id;
  final String name;
  final bool isFolder;
  final int? sizeBytes;
  final String? parentId;

  static const _videoExtensions = <String>{
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'm4v',
    'webm',
    'ts',
    'm2ts',
    'mpg',
    'mpeg',
    'flv',
  };

  bool get isVideo {
    if (isFolder) return false;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    return _videoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }
}

class TorrentCheapFolderPage {
  const TorrentCheapFolderPage({
    required this.entries,
    this.nextPageToken,
  });

  final List<TorrentCheapCloudEntry> entries;

  /// Opaque continuation token. Null when there are no more entries.
  final String? nextPageToken;
}

/// What a transport returns when asked to play a cloud file.
///
/// TorrentCheap's browser player streams transcoded HLS. Whether an external
/// client may fetch the playlist, and with which headers, is unverified, so
/// the headers are carried explicitly instead of being assumed empty.
class TorrentCheapPlaybackSource {
  const TorrentCheapPlaybackSource({
    required this.masterPlaylistUri,
    this.httpHeaders = const <String, String>{},
    this.expiresAt,
    this.isTranscoded = true,
  });

  final Uri masterPlaylistUri;
  final Map<String, String> httpHeaders;

  /// When the URL stops working, if the provider says so.
  final DateTime? expiresAt;

  /// True for the provider's HLS renditions; false only if a transport ever
  /// proves access to the original file bytes.
  final bool isTranscoded;

  bool isExpiredAt(DateTime now, {Duration margin = Duration.zero}) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !now.add(margin).isBefore(expiry);
  }
}

enum TorrentCheapErrorKind {
  /// The experimental adapter is compiled out or has no authorized transport.
  unavailable,
  notConnected,
  unauthorized,
  sessionExpired,
  invalidMagnet,
  invalidSelection,
  taskLimitReached,
  quotaExceeded,
  rateLimited,
  notFound,
  streamExpired,
  unsupportedStream,
  stalled,
  timeout,
  network,
  provider,
}

class TorrentCheapException implements Exception {
  const TorrentCheapException(this.kind, this.message);

  final TorrentCheapErrorKind kind;
  final String message;

  bool get requiresReconnect =>
      kind == TorrentCheapErrorKind.notConnected ||
      kind == TorrentCheapErrorKind.unauthorized ||
      kind == TorrentCheapErrorKind.sessionExpired;

  @override
  String toString() => message;
}
