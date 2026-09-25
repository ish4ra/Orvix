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
        let is_video = |file: &crate::backend::BackendFileInfo| {
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

    text = replace_once(
        text,
        '        let mut cmd = tokio::process::Command::new("ffmpeg");\n',
        '        let mut cmd = tokio::process::Command::new("ffmpeg");\n'
        '        #[cfg(windows)]\n'
        '        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW\n',
        "hide exact-subtitle ffmpeg console",
    )

    ffprobe_anchor = '''    let output = tokio::process::Command::new("ffprobe")
        .args([
'''
    ffprobe_replacement = '''    let mut cmd = tokio::process::Command::new("ffprobe");
    #[cfg(windows)]
    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    let output = cmd
        .args([
'''
    text = replace_once(
        text,
        ffprobe_anchor,
        ffprobe_replacement,
        "hide exact-subtitle ffprobe console",
    )

    path.write_text(text, encoding="utf-8")


def patch_ffmpeg_setup(root: pathlib.Path) -> None:
    path = root / "server" / "src" / "ffmpeg_setup.rs"
    text = path.read_text(encoding="utf-8")

    anchor = '''fn command_available(command: &str) -> bool {
    Command::new(command)
        .arg("-version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
'''
    replacement = '''fn command_available(command: &str) -> bool {
    let mut cmd = Command::new(command);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    cmd.arg("-version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
'''
    text = replace_once(
        text,
        anchor,
        replacement,
        "hide FFmpeg availability-check console",
    )
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
        "remoteEmbeddedSubtitles": true,
        "remoteSubtitleRouteVersion": 1,
        "audioWindowExtraction": true,
        "audioWindowRouteVersion": 1,
    }))
}

#[derive(serde::Deserialize)]
pub struct OrvixAudioWindowQuery {
    #[serde(rename = "videoUrl")]
    pub video_url: String,
    #[serde(rename = "startMs")]
    pub start_ms: u64,
    #[serde(rename = "durationMs")]
    pub duration_ms: u64,
}

pub async fn orvix_audio_window(
    Json(query): Json<OrvixAudioWindowQuery>,
) -> Response {
    let video_url = query.video_url.trim();
    if !(video_url.starts_with("http://") || video_url.starts_with("https://")) {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(axum::body::Body::from("videoUrl must be HTTP/HTTPS"))
            .unwrap();
    }
    if query.duration_ms < 1000 || query.duration_ms > 30000 {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(axum::body::Body::from(
                "durationMs must be between 1000 and 30000",
            ))
            .unwrap();
    }

    let start_seconds = format!("{:.3}", query.start_ms as f64 / 1000.0);
    let duration_seconds = format!("{:.3}", query.duration_ms as f64 / 1000.0);
    let mut cmd = tokio::process::Command::new("ffmpeg");
    cmd.kill_on_drop(true);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }

    cmd.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-rw_timeout",
        "30000000",
        "-ss",
        &start_seconds,
        "-t",
        &duration_seconds,
        "-i",
        video_url,
        "-map",
        "0:a:0?",
        "-vn",
        "-sn",
        "-dn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "aac",
        "-b:a",
        "32k",
        "-f",
        "adts",
        "-",
    ]);

    let output = match tokio::time::timeout(
        std::time::Duration::from_secs(45),
        cmd.output(),
    )
    .await
    {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            return Response::builder()
                .status(StatusCode::BAD_GATEWAY)
                .body(axum::body::Body::from(format!(
                    "Audio extraction launch failed: {error}"
                )))
                .unwrap();
        }
        Err(_) => {
            return Response::builder()
                .status(StatusCode::GATEWAY_TIMEOUT)
                .body(axum::body::Body::from("Audio extraction timed out"))
                .unwrap();
        }
    };

    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim().chars().take(600).collect::<String>();
        return Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(axum::body::Body::from(format!(
                "Audio extraction failed: {detail}"
            )))
            .unwrap();
    }
    if output.stdout.len() < 256 {
        return Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(axum::body::Body::from(
                "Audio extraction produced no usable bytes",
            ))
            .unwrap();
    }
    if output.stdout.len() > 850_000 {
        return Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(axum::body::Body::from(
                "Audio extraction produced an unexpectedly large window",
            ))
            .unwrap();
    }

    Response::builder()
        .header("content-type", "audio/aac")
        .header("cache-control", "no-store")
        .header("access-control-allow-origin", "*")
        .body(axum::body::Body::from(output.stdout))
        .unwrap()
}

#[derive(serde::Deserialize)]
pub struct OrvixRemoteVideoQuery {
    #[serde(rename = "videoUrl")]
    pub video_url: String,
}

async fn probe_remote_embedded_subtitles(
    video_url: &str,
) -> Result<Vec<(usize, String, String, String)>, String> {
    let mut cmd = tokio::process::Command::new("ffprobe");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }

    let output = cmd
        .args([
            "-v",
            "error",
            "-rw_timeout",
            "30000000",
            "-probesize",
            "12000000",
            "-analyzeduration",
            "12000000",
            "-select_streams",
            "s",
            "-show_entries",
            "stream=codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
            "-of",
            "json",
            video_url,
        ])
        .output()
        .await
        .map_err(|error| format!("ffprobe launch failed: {error}"))?;

    if !output.status.success() {
        return Err(format!(
            "ffprobe failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let decoded: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|error| error.to_string())?;
    let streams = decoded
        .get("streams")
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();

    let text_codecs = ["ass", "ssa", "subrip", "webvtt", "mov_text", "text"];
    let mut tracks = Vec::new();
    for (subtitle_index, stream) in streams.iter().enumerate() {
        let codec = stream
            .get("codec_name")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_lowercase();
        if !text_codecs.contains(&codec.as_str()) {
            continue;
        }

        let tags = stream.get("tags");
        let language = tags
            .and_then(|value| value.get("language"))
            .and_then(|value| value.as_str())
            .unwrap_or("und")
            .to_string();
        let title = tags
            .and_then(|value| value.get("title"))
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string();

        let disposition = stream.get("disposition");
        let forced = disposition
            .and_then(|value| value.get("forced"))
            .and_then(|value| value.as_i64())
            .unwrap_or(0)
            != 0;
        let hearing_impaired = disposition
            .and_then(|value| value.get("hearing_impaired"))
            .and_then(|value| value.as_i64())
            .unwrap_or(0)
            != 0;

        let mut label_parts = Vec::new();
        if !title.trim().is_empty() {
            label_parts.push(title.trim().to_string());
        }
        label_parts.push(language.clone());
        label_parts.push(codec.clone());
        if forced {
            label_parts.push("forced".to_string());
        }
        if hearing_impaired {
            label_parts.push("hearing impaired".to_string());
        }

        tracks.push((
            1000 + subtitle_index,
            language,
            label_parts.join(" • "),
            codec,
        ));
    }

    Ok(tracks)
}

pub async fn orvix_remote_subtitles_tracks(
    Query(query): Query<OrvixRemoteVideoQuery>,
) -> impl IntoResponse {
    match probe_remote_embedded_subtitles(&query.video_url).await {
        Ok(tracks) => {
            let result = tracks
                .into_iter()
                .map(|(id, language, label, codec)| {
                    json!({
                        "id": id,
                        "lang": language,
                        "label": label,
                        "codec": codec,
                        "embedded": true,
                        "url": format!("/orvix/remote/embedded/{}/subtitles.vtt", id),
                    })
                })
                .collect::<Vec<_>>();
            Json(json!({
                "error": null,
                "result": result,
                "orvixRemoteFile": true,
            }))
        }
        Err(error) => Json(json!({
            "error": error,
            "result": [],
            "orvixRemoteFile": true,
        })),
    }
}

#[derive(serde::Deserialize)]
pub struct OrvixRemoteExtractQuery {
    #[serde(rename = "videoUrl")]
    pub video_url: String,
}

pub async fn get_remote_embedded_subtitles_vtt(
    Path(track_id): Path<usize>,
    Query(query): Query<OrvixRemoteExtractQuery>,
) -> Response {
    if track_id < 1000 {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(axum::body::Body::from("Invalid embedded subtitle track ID"))
            .unwrap();
    }

    let subtitle_index = track_id - 1000;
    let map_value = format!("0:s:{subtitle_index}");
    let mut cmd = tokio::process::Command::new("ffmpeg");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }

    let output = match cmd
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-rw_timeout",
            "30000000",
            "-i",
            &query.video_url,
            "-map",
            &map_value,
            "-vn",
            "-an",
            "-dn",
            "-c:s",
            "webvtt",
            "-f",
            "webvtt",
            "-",
        ])
        .output()
        .await
    {
        Ok(output) => output,
        Err(error) => {
            return Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(axum::body::Body::from(format!(
                    "Remote subtitle extraction launch failed: {error}"
                )))
                .unwrap();
        }
    };

    if !output.status.success() {
        return Response::builder()
            .status(StatusCode::INTERNAL_SERVER_ERROR)
            .body(axum::body::Body::from(format!(
                "Remote subtitle extraction failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )))
            .unwrap();
    }

    match String::from_utf8(output.stdout) {
        Ok(content) if content.contains("-->") => Response::builder()
            .header("content-type", "text/vtt")
            .header("access-control-allow-origin", "*")
            .header("x-orvix-remote-file", "1")
            .body(axum::body::Body::from(content))
            .unwrap(),
        Ok(_) => Response::builder()
            .status(StatusCode::UNPROCESSABLE_ENTITY)
            .body(axum::body::Body::from(
                "Remote subtitle extraction produced no timed cues",
            ))
            .unwrap(),
        Err(error) => Response::builder()
            .status(StatusCode::INTERNAL_SERVER_ERROR)
            .body(axum::body::Body::from(format!(
                "Remote subtitle output was not UTF-8: {error}"
            )))
            .unwrap(),
    }
}

#[derive(serde::Deserialize)]
pub struct OrvixResolveFileQuery {
    pub hint: Option<String>,
}

pub async fn orvix_resolve_file(
    State(state): State<AppState>,
    Path(info_hash): Path<String>,
    Query(query): Query<OrvixResolveFileQuery>,
) -> impl IntoResponse {
    let info_hash = info_hash.to_lowercase();
    let Some(engine) = state.stream_engine().get_engine(&info_hash).await else {
        return Json(json!({
            "error": "Torrent engine not found",
            "fileIdx": null,
        }));
    };

    let files = engine.handle.get_files().await;
    let candidates = files
        .iter()
        .enumerate()
        .map(|(index, file)| crate::routes::compat::FileCandidate {
            index,
            name: file.name.clone(),
            length: file.length,
        })
        .collect::<Vec<_>>();

    let filters = query
        .hint
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .into_iter()
        .collect::<Vec<_>>();

    match crate::routes::compat::resolve_file_idx("-1", &candidates, &filters) {
        Ok(file_idx) => {
            let file_name = files
                .get(file_idx)
                .map(|file| file.name.clone())
                .unwrap_or_default();
            Json(json!({
                "error": null,
                "fileIdx": file_idx,
                "fileName": file_name,
                "usedHint": !filters.is_empty(),
            }))
        }
        Err(error) => Json(json!({
            "error": error,
            "fileIdx": null,
        })),
    }
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

    text = replace_once(
        text,
        "routing::get",
        "routing::{get, post}",
        "server post route import",
    )

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
            "/orvix/{infoHash}/resolve-file",
            get(routes::subtitles::orvix_resolve_file),
        )
        .route(
            "/orvix/remote/subtitlesTracks",
            get(routes::subtitles::orvix_remote_subtitles_tracks),
        )
        .route(
            "/orvix/audio-window",
            post(routes::subtitles::orvix_audio_window),
        )
        .route(
            "/orvix/remote/embedded/{trackId}/subtitles.vtt",
            get(routes::subtitles::get_remote_embedded_subtitles_vtt),
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
    ffmpeg_setup = (
        root / "server" / "src" / "ffmpeg_setup.rs"
    ).read_text(encoding="utf-8")
    lib = (root / "server" / "src" / "lib.rs").read_text(encoding="utf-8")

    required = [
        ("find_subtitle_tracks_for_file", engine),
        ("selected_file_idx", engine),
        ("creation_flags(0x08000000)", engine),
        ("creation_flags(0x08000000)", ffmpeg_setup),
        ("orvix_capabilities", subtitles),
        ("orvix_resolve_file", subtitles),
        ("exactFileEmbeddedSubtitles", subtitles),
        ("remoteEmbeddedSubtitles", subtitles),
        ("audioWindowExtraction", subtitles),
        ("orvix_audio_window", subtitles),
        ("orvix_remote_subtitles_tracks", subtitles),
        ("get_remote_embedded_subtitles_vtt", subtitles),
        ("get_exact_embedded_subtitles_vtt", subtitles),
        ("orvixExactFile", subtitles),
        ('"/orvix/capabilities"', lib),
        ('"/orvix/{infoHash}/resolve-file"', lib),
        ('"/orvix/remote/subtitlesTracks"', lib),
        ('"/orvix/audio-window"', lib),
        ('"/orvix/remote/embedded/{trackId}/subtitles.vtt"', lib),
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
    patch_ffmpeg_setup(root)
    patch_subtitles_route(root)
    patch_router(root)
    verify(root)
    print(
        "Orvix exact-file subtitle patch applied successfully "
        f"against upstream {PINNED_UPSTREAM}."
    )


if __name__ == "__main__":
    main()
