#!/usr/bin/env python3
"""Patch pinned upstream stream-server with Orvix exact-file subtitle routes.

Usage:
  python tools/patch_orvix_stream_server.py <stream-server checkout>

The patch is intentionally applied by exact source anchors against the pinned
upstream commit. If upstream source changes, the script fails instead of
silently producing a partially patched binary.
"""

from __future__ import annotations

import pathlib
import sys

PINNED_UPSTREAM = "f585ab6eda9b1411034548c131bb0dc30c6f5f9e"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{label}: expected exactly one source anchor, found {count}. "
            "Pinned upstream may have changed."
        )
    return text.replace(old, new, 1)


def patch_engine(root: pathlib.Path) -> None:
    path = root / "enginefs" / "src" / "engine.rs"
    text = path.read_text(encoding="utf-8")

    start = text.index("    pub async fn find_subtitle_tracks(&self) -> Vec<SubtitleTrack> {")
    end = text.index("    pub async fn get_peer_stats(&self) -> Vec<PeerStat> {", start)

    replacement = r'''    pub async fn find_subtitle_tracks(&self) -> Vec<SubtitleTrack> {
        self.find_subtitle_tracks_inner(None).await
    }

    /// Orvix extension: discover embedded subtitle tracks from one exact
    /// torrent video file instead of guessing the largest file in a pack.
    pub async fn find_subtitle_tracks_for_file(
        &self,
        file_idx: usize,
    ) -> Vec<SubtitleTrack> {
        self.find_subtitle_tracks_inner(Some(file_idx)).await
    }

    async fn find_subtitle_tracks_inner(
        &self,
        selected_file_idx: Option<usize>,
    ) -> Vec<SubtitleTrack> {
        tracing::info!(
            "[SUBTITLES] find_subtitle_tracks called for info_hash={} selected_file_idx={:?}",
            self.info_hash,
            selected_file_idx
        );
        let mut tracks = Vec::new();
        let files = self.handle.get_files().await;

        // Keep upstream external-subtitle discovery unchanged. These IDs are
        // real torrent file indexes and are still served by the legacy route.
        for (idx, file) in files.iter().enumerate() {
            let filename = file.name.clone();
            let path = std::path::PathBuf::from(&filename);
            if let Some(ext) = path.extension()
                && let Some(ext_str) = ext.to_str()
            {
                let ext_lower = ext_str.to_lowercase();
                if ["srt", "vtt", "sub", "idx", "txt", "ssa", "ass"]
                    .contains(&ext_lower.as_str())
                {
                    tracing::info!("[SUBTITLES] Found external subtitle: {}", filename);
                    tracks.push(SubtitleTrack {
                        id: idx,
                        name: filename,
                        size: file.length,
                    });
                }
            }
        }

        let video_extensions = ["mkv", "mp4", "avi", "webm", "mov"];
        let is_video = |file: &_| {
            let path = std::path::PathBuf::from(&file.name);
            path.extension()
                .and_then(|e| e.to_str())
                .map(|e| video_extensions.contains(&e.to_lowercase().as_str()))
                .unwrap_or(false)
        };

        // Upstream compatibility: without an exact index, preserve the old
        // largest-video heuristic. Orvix always supplies the selected file.
        let video_file = if let Some(file_idx) = selected_file_idx {
            files
                .get(file_idx)
                .filter(|file| is_video(file))
                .map(|file| (file_idx, file))
        } else {
            files
                .iter()
                .enumerate()
                .filter(|(_, file)| is_video(file))
                .max_by_key(|(_, file)| file.length)
        };

        if let Some((file_idx, file)) = video_file {
            tracing::info!(
                "[SUBTITLES] Probing video file: {} (idx={})",
                file.name,
                file_idx
            );

            if let Some(file_path) = self.handle.get_file_path(file_idx).await {
                if let Err(e) = self.handle.prepare_file_for_streaming(file_idx).await {
                    tracing::warn!(
                        "[SUBTITLES] prepare_file_for_streaming failed for idx={}: {}",
                        file_idx,
                        e
                    );
                }

                tracing::info!("[SUBTITLES] Probing file at path: {}", file_path);
                match probe_embedded_subtitles(&file_path).await {
                    Ok(embedded) => {
                        tracing::info!(
                            "[SUBTITLES] Probed {} embedded tracks from idx={}",
                            embedded.len(),
                            file_idx
                        );
                        for (stream_idx, lang, title) in embedded {
                            let id = 1000 + stream_idx;
                            let name = if let Some(t) = title {
                                format!(
                                    "{} ({})",
                                    t,
                                    lang.unwrap_or_else(|| "und".to_string())
                                )
                            } else {
                                format!(
                                    "Track {} ({})",
                                    stream_idx,
                                    lang.unwrap_or_else(|| "und".to_string())
                                )
                            };
                            tracks.push(SubtitleTrack {
                                id,
                                name,
                                size: 0,
                            });
                        }
                    }
                    Err(e) => {
                        tracing::error!(
                            "[SUBTITLES] Probe failed for exact file idx={}: {}",
                            file_idx,
                            e
                        );
                    }
                }
            } else {
                tracing::warn!(
                    "[SUBTITLES] Could not get file path for probing idx={}",
                    file_idx
                );
            }
        } else if let Some(file_idx) = selected_file_idx {
            tracing::warn!(
                "[SUBTITLES] Selected file idx={} is missing or not a supported video",
                file_idx
            );
        } else {
            tracing::warn!("[SUBTITLES] No main video file found to probe");
        }

        tracks
    }

'''
    text = text[:start] + replacement + text[end:]
    path.write_text(text, encoding="utf-8")


def patch_subtitles_route(root: pathlib.Path) -> None:
    path = root / "server" / "src" / "routes" / "subtitles.rs"
    text = path.read_text(encoding="utf-8")

    start = text.index("#[derive(serde::Deserialize)]\npub struct SubtitlesTracksQuery")
    end = text.index("\npub async fn get_subtitles_vtt(", start)

    replacement = r'''#[derive(serde::Deserialize)]
pub struct SubtitlesTracksQuery {
    #[serde(rename = "subsUrl")]
    pub subs_url: Option<String>,
}

fn torrent_file_from_url(url: &str) -> (Option<String>, Option<usize>) {
    let parts: Vec<&str> = url.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        if part.len() != 40 || hex::decode(part).is_err() {
            continue;
        }

        let info_hash = part.to_lowercase();
        let file_idx = parts.get(i + 1).and_then(|value| {
            value
                .split('?')
                .next()
                .and_then(|raw| raw.parse::<usize>().ok())
        });
        return (Some(info_hash), file_idx);
    }
    (None, None)
}

pub async fn subtitles_tracks(
    State(state): State<AppState>,
    Query(query): Query<SubtitlesTracksQuery>,
) -> impl IntoResponse {
    let url = query.subs_url.unwrap_or_default();
    let (info_hash, selected_file_idx) = torrent_file_from_url(&url);

    if let Some(info_hash) = info_hash
        && let Some(engine) = state.stream_engine().get_engine(&info_hash).await
    {
        let tracks: Vec<SubtitleTrack> = match selected_file_idx {
            Some(file_idx) => engine.find_subtitle_tracks_for_file(file_idx).await,
            None => engine.find_subtitle_tracks().await,
        };

        let result: Vec<serde_json::Value> = tracks
            .into_iter()
            .map(|t| {
                let embedded = t.id >= 1000;
                let url = if embedded {
                    if let Some(file_idx) = selected_file_idx {
                        format!(
                            "/{}/{}/embedded/{}/subtitles.vtt",
                            info_hash, file_idx, t.id
                        )
                    } else {
                        // Preserve upstream compatibility when no selected file
                        // index was supplied.
                        format!("/{}/{}/subtitles.vtt", info_hash, t.id)
                    }
                } else {
                    format!("/{}/{}/subtitles.vtt", info_hash, t.id)
                };

                json!({
                    "id": t.id,
                    "lang": "Unknown",
                    "label": t.name,
                    "url": url,
                    "embedded": embedded,
                    "videoFileIdx": selected_file_idx,
                })
            })
            .collect();

        return Json(json!({
            "error": null,
            "result": result,
            "orvixExactFile": selected_file_idx.is_some(),
        }));
    }

    Json(json!({ "error": null, "result": [], "orvixExactFile": false }))
}

pub async fn orvix_capabilities() -> impl IntoResponse {
    Json(json!({
        "name": "orvix-stream-server",
        "exactFileEmbeddedSubtitles": true,
        "exactSubtitleRouteVersion": 1,
    }))
}

/// Orvix extension: extract one embedded subtitle stream from the exact
/// selected torrent video file. The original upstream route is retained for
/// compatibility with clients that still use the largest-file heuristic.
pub async fn get_exact_embedded_subtitles_vtt(
    State(state): State<AppState>,
    Path((info_hash, file_idx, track_id)): Path<(String, usize, usize)>,
) -> Response {
    if track_id < 1000 {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(axum::body::Body::from("Invalid embedded subtitle track ID"))
            .unwrap();
    }

    if let Some(engine) = state
        .stream_engine()
        .get_engine(&info_hash.to_lowercase())
        .await
    {
        match engine.extract_embedded_subtitle(file_idx, track_id).await {
            Ok(content) => {
                return Response::builder()
                    .header("content-type", "text/vtt")
                    .header("access-control-allow-origin", "*")
                    .header("x-orvix-exact-file", "1")
                    .body(axum::body::Body::from(content))
                    .unwrap();
            }
            Err(e) => {
                return Response::builder()
                    .status(StatusCode::INTERNAL_SERVER_ERROR)
                    .body(axum::body::Body::from(format!(
                        "Exact subtitle extraction failed: {}",
                        e
                    )))
                    .unwrap();
            }
        }
    }

    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(axum::body::Body::from("Torrent engine not found"))
        .unwrap()
}

'''
    text = text[:start] + replacement + text[end:]
    path.write_text(text, encoding="utf-8")


def patch_router(root: pathlib.Path) -> None:
    path = root / "server" / "src" / "lib.rs"
    text = path.read_text(encoding="utf-8")

    anchor = '''        .route(
            "/{infoHash}/{fileIdx}/subtitles.vtt",
            get(routes::subtitles::get_subtitles_vtt),
        )
'''
    replacement = '''        .route(
            "/orvix/capabilities",
            get(routes::subtitles::orvix_capabilities),
        )
        .route(
            "/{infoHash}/{fileIdx}/embedded/{trackId}/subtitles.vtt",
            get(routes::subtitles::get_exact_embedded_subtitles_vtt),
        )
''' + anchor

    text = replace_once(
        text,
        anchor,
        replacement,
        "server exact embedded subtitle route",
    )
    path.write_text(text, encoding="utf-8")


def verify(root: pathlib.Path) -> None:
    engine = (root / "enginefs" / "src" / "engine.rs").read_text(encoding="utf-8")
    subtitles = (
        root / "server" / "src" / "routes" / "subtitles.rs"
    ).read_text(encoding="utf-8")
    lib = (root / "server" / "src" / "lib.rs").read_text(encoding="utf-8")

    required = [
        ("find_subtitle_tracks_for_file", engine),
        ("selected_file_idx", engine),
        ("orvix_capabilities", subtitles),
        ("exactFileEmbeddedSubtitles", subtitles),
        ("get_exact_embedded_subtitles_vtt", subtitles),
        ("orvixExactFile", subtitles),
        ('"/orvix/capabilities"', lib),
        ('"/{infoHash}/{fileIdx}/embedded/{trackId}/subtitles.vtt"', lib),
    ]
    missing = [needle for needle, haystack in required if needle not in haystack]
    if missing:
        raise SystemExit(f"Patch verification failed, missing: {missing}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_orvix_stream_server.py <stream-server checkout>")
    root = pathlib.Path(sys.argv[1]).resolve()
    if not (root / "Cargo.toml").exists():
        raise SystemExit(f"not a stream-server checkout: {root}")

    patch_engine(root)
    patch_subtitles_route(root)
    patch_router(root)
    verify(root)
    print(
        "Orvix exact-file subtitle patch applied successfully "
        f"against upstream {PINNED_UPSTREAM}."
    )


if __name__ == "__main__":
    main()
