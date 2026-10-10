package com.orvix.orvix

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.ForwardingRenderer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * Orvix's Android ExoPlayer (Media3) bridge. Video renders into a Flutter
 * texture, so the whole player UI, including Android TV DPAD focus, stays in
 * Flutter. Subtitle cues, tracks, state and errors are sent to Dart on the
 * "orvix/exo_player" channel; Dart renders subtitles in Orvix's style.
 */
@OptIn(markerClass = [UnstableApi::class])
class OrvixExoPlayerChannel(
    context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, "orvix/exo_player")
    private val sessions = HashMap<Long, OrvixExoSession>()
    private var nextId = 1L

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (call.method == "create") {
                val id = nextId++
                val session = OrvixExoSession(
                    id = id,
                    context = appContext,
                    producer = textures.createSurfaceProducer(),
                    channel = channel,
                    url = call.argument<String>("url") ?: "",
                    headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                    patientStartup = call.argument<Boolean>("patientStartup") ?: false,
                    preferredTextLanguage = call.argument<String>("preferredTextLanguage"),
                    preferredAudioLanguage = call.argument<String>("preferredAudioLanguage"),
                    startMs = number(call, "startMs") ?: 0L,
                )
                sessions[id] = session
                result.success(
                    mapOf(
                        "id" to id,
                        "textureId" to session.textureId,
                        "handlesCropAndRotation" to session.handlesCropAndRotation,
                    )
                )
                return
            }
            val id = number(call, "id")
            val session = if (id == null) null else sessions[id]
            if (id == null || session == null) {
                // A late command for a player that already closed is harmless.
                result.success(null)
                return
            }
            when (call.method) {
                "play" -> session.player.play()
                "pause" -> session.player.pause()
                "seekTo" -> session.player.seekTo(number(call, "positionMs") ?: 0L)
                "setSpeed" -> {
                    val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                    session.player.playbackParameters = PlaybackParameters(speed)
                }
                "selectTrack" -> session.selectTrack(
                    type = call.argument<String>("type") ?: "",
                    group = (number(call, "group") ?: -1L).toInt(),
                    track = (number(call, "track") ?: -1L).toInt(),
                )
                "setSubtitleOffset" -> session.setSubtitleOffsetMs(
                    number(call, "offsetMs") ?: 0L
                )
                "dispose" -> {
                    sessions.remove(id)?.release()
                }
                else -> {
                    result.notImplemented()
                    return
                }
            }
            result.success(null)
        } catch (error: Throwable) {
            result.error(
                "exo_player_error",
                "${error::class.java.simpleName}: ${error.message ?: ""}",
                null,
            )
        }
    }

    fun releaseAll() {
        for (session in sessions.values) session.release()
        sessions.clear()
    }

    private fun number(call: MethodCall, key: String): Long? =
        (call.argument<Any>(key) as? Number)?.toLong()
}

@OptIn(markerClass = [UnstableApi::class])
private class OrvixExoSession(
    private val id: Long,
    context: Context,
    private val producer: TextureRegistry.SurfaceProducer,
    private val channel: MethodChannel,
    url: String,
    headers: Map<String, String>,
    patientStartup: Boolean,
    preferredTextLanguage: String?,
    preferredAudioLanguage: String?,
    startMs: Long,
) : Player.Listener, TextureRegistry.SurfaceProducer.Callback {
    private val main = Handler(Looper.getMainLooper())
    private val subtitleOffsetUs = AtomicLong(0L)
    private var released = false
    private var needsSurface = false
    private var lastTracks: Tracks = Tracks.EMPTY

    val textureId: Long = producer.id()
    val handlesCropAndRotation: Boolean = producer.handlesCropAndRotation()
    val player: ExoPlayer

    private val ticker = object : Runnable {
        override fun run() {
            if (released) return
            sendState()
            main.postDelayed(this, 500L)
        }
    }

    init {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("Orvix")
            .setConnectTimeoutMs(if (patientStartup) 30_000 else 15_000)
            .setReadTimeoutMs(if (patientStartup) 60_000 else 20_000)
            .setDefaultRequestProperties(headers)
        val mediaSources = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(http)
            .setLoadErrorHandlingPolicy(
                if (patientStartup) PatientLoadErrorPolicy() else DefaultLoadErrorHandlingPolicy()
            )
        val offset = subtitleOffsetUs
        val renderers = object : DefaultRenderersFactory(context) {
            override fun buildTextRenderers(
                context: Context,
                output: TextOutput,
                outputLooper: Looper,
                extensionRendererMode: Int,
                out: ArrayList<Renderer>,
            ) {
                val start = out.size
                super.buildTextRenderers(context, output, outputLooper, extensionRendererMode, out)
                for (index in start until out.size) {
                    out[index] = SubtitleOffsetRenderer(out[index], offset)
                }
            }
        }.setEnableDecoderFallback(true)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(20_000, 60_000, 2_500, 5_000)
            .build()
        player = ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(mediaSources)
            .setLoadControl(loadControl)
            .build()
        val params = player.trackSelectionParameters.buildUpon()
        if (!preferredTextLanguage.isNullOrBlank()) {
            params.setPreferredTextLanguage(preferredTextLanguage)
        }
        if (!preferredAudioLanguage.isNullOrBlank()) {
            params.setPreferredAudioLanguage(preferredAudioLanguage)
        }
        player.trackSelectionParameters = params.build()
        player.addListener(this)

        producer.setCallback(this)
        val surface = producer.getSurface()
        player.setVideoSurface(surface)
        needsSurface = surface == null

        player.setMediaItem(MediaItem.fromUri(url), startMs.coerceAtLeast(0L))
        player.playWhenReady = true
        player.prepare()
        main.post(ticker)
    }

    override fun onSurfaceAvailable() {
        if (released || !needsSurface) return
        player.setVideoSurface(producer.getSurface())
        needsSurface = false
    }

    override fun onSurfaceCleanup() {
        if (released) return
        player.setVideoSurface(null)
        needsSurface = true
    }

    fun setSubtitleOffsetMs(offsetMs: Long) {
        subtitleOffsetUs.set(offsetMs * 1000L)
    }

    fun selectTrack(type: String, group: Int, track: Int) {
        val trackType = if (type == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
        val builder = player.trackSelectionParameters.buildUpon()
        if (group < 0) {
            if (trackType == C.TRACK_TYPE_TEXT) {
                builder.clearOverridesOfType(C.TRACK_TYPE_TEXT)
                builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            }
        } else {
            val groups = lastTracks.groups
            if (group >= groups.size) return
            val selected = groups[group]
            if (selected.type != trackType || track >= selected.length) return
            builder.setTrackTypeDisabled(trackType, false)
            builder.setOverrideForType(TrackSelectionOverride(selected.mediaTrackGroup, track))
        }
        player.trackSelectionParameters = builder.build()
    }

    override fun onPlaybackStateChanged(playbackState: Int) = sendState()

    override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        var width = videoSize.width
        val height = videoSize.height
        if (width <= 0 || height <= 0) return
        val ratio = videoSize.pixelWidthHeightRatio
        if (ratio > 0f && ratio != 1f) width = maxOf(1, Math.round(width * ratio))
        val rotation = if (handlesCropAndRotation) 0 else (player.videoFormat?.rotationDegrees ?: 0)
        send(mapOf("event" to "video", "width" to width, "height" to height, "rotation" to rotation))
    }

    override fun onTracksChanged(tracks: Tracks) {
        lastTracks = tracks
        val list = ArrayList<Map<String, Any?>>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            val type = when (group.type) {
                C.TRACK_TYPE_AUDIO -> "audio"
                C.TRACK_TYPE_TEXT -> "text"
                else -> null
            } ?: return@forEachIndexed
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                list.add(
                    mapOf(
                        "type" to type,
                        "group" to groupIndex,
                        "track" to trackIndex,
                        "language" to format.language,
                        "label" to format.label,
                        "mimeType" to (format.sampleMimeType ?: format.containerMimeType),
                        "codecs" to format.codecs,
                        "channels" to format.channelCount,
                        "selected" to group.isTrackSelected(trackIndex),
                        "supported" to group.isTrackSupported(trackIndex),
                        "forced" to ((format.selectionFlags and C.SELECTION_FLAG_FORCED) != 0),
                        "isDefault" to ((format.selectionFlags and C.SELECTION_FLAG_DEFAULT) != 0),
                    )
                )
            }
        }
        send(mapOf("event" to "tracks", "tracks" to list))
    }

    override fun onCues(cueGroup: CueGroup) {
        val lines = ArrayList<String>()
        val bitmaps = ArrayList<Map<String, Any?>>()
        for (cue in cueGroup.cues) {
            val text = cue.text?.toString()?.trim()
            if (!text.isNullOrEmpty()) lines.add(text)
            val bitmap = cue.bitmap ?: continue
            bitmaps.add(
                mapOf(
                    "png" to png(bitmap),
                    "left" to fraction(cue.position, cue.positionAnchor, cue.size),
                    "top" to fraction(cue.line, cue.lineAnchor, cue.bitmapHeight),
                    "width" to cue.size.toDouble(),
                    "height" to cue.bitmapHeight.toDouble(),
                )
            )
        }
        send(mapOf("event" to "cues", "text" to lines, "bitmaps" to bitmaps))
    }

    override fun onPlayerError(error: PlaybackException) {
        send(
            mapOf(
                "event" to "error",
                "code" to error.errorCodeName,
                "message" to (error.message ?: error.errorCodeName),
                "cause" to (error.cause?.toString() ?: ""),
            )
        )
        sendState()
    }

    private fun fraction(value: Float, anchor: Int, size: Float): Double? {
        if (value == Cue.DIMEN_UNSET) return null
        val extent = if (size == Cue.DIMEN_UNSET) 0f else size
        return when (anchor) {
            Cue.ANCHOR_TYPE_MIDDLE -> (value - extent / 2f).toDouble()
            Cue.ANCHOR_TYPE_END -> (value - extent).toDouble()
            else -> value.toDouble()
        }
    }

    private fun png(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun sendState() {
        if (released) return
        val duration = player.duration
        send(
            mapOf(
                "event" to "state",
                "state" to player.playbackState,
                "playing" to player.isPlaying,
                "playWhenReady" to player.playWhenReady,
                "positionMs" to player.currentPosition,
                "durationMs" to if (duration == C.TIME_UNSET) -1L else duration,
                "bufferedMs" to player.bufferedPosition,
                "speed" to player.playbackParameters.speed.toDouble(),
                "hasError" to (player.playerError != null),
            )
        )
    }

    private fun send(event: Map<String, Any?>) {
        if (released) return
        val payload = HashMap(event)
        payload["id"] = id
        channel.invokeMethod("event", payload)
    }

    fun release() {
        if (released) return
        released = true
        main.removeCallbacks(ticker)
        player.removeListener(this)
        player.release()
        producer.release()
    }
}

/**
 * A local Free P2P torrent may need minutes before its first bytes arrive.
 * Read timeouts while the swarm is still connecting are retried for as long as
 * the player is open, so ExoPlayer never gives up on a slow-but-live torrent.
 * Errors that slowness cannot cause (a missing file or route, unparseable
 * media) stay fatal.
 */
@OptIn(markerClass = [UnstableApi::class])
private class PatientLoadErrorPolicy : DefaultLoadErrorHandlingPolicy() {
    override fun getMinimumLoadableRetryCount(dataType: Int): Int = Int.MAX_VALUE

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        val error = loadErrorInfo.exception
        if (error is HttpDataSource.InvalidResponseCodeException && error.responseCode in 400..499) {
            return C.TIME_UNSET
        }
        val base = super.getRetryDelayMsFor(loadErrorInfo)
        if (base == C.TIME_UNSET) return C.TIME_UNSET
        return base.coerceIn(1_000L, 3_000L)
    }
}

/** Shifts subtitle presentation by the user's timing offset. */
@OptIn(markerClass = [UnstableApi::class])
private class SubtitleOffsetRenderer(
    renderer: Renderer,
    private val offsetUs: AtomicLong,
) : ForwardingRenderer(renderer) {
    override fun render(positionUs: Long, elapsedRealtimeUs: Long) {
        super.render((positionUs - offsetUs.get()).coerceAtLeast(0L), elapsedRealtimeUs)
    }
}
