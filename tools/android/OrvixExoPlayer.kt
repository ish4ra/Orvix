package com.orvix.orvix

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
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
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.ForwardingRenderer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Orvix's Android ExoPlayer (Media3) bridge. Video renders into a Flutter
 * texture, so the whole player UI, including Android TV DPAD focus, stays in
 * Flutter. Subtitle cues, tracks, state, privacy-safe diagnostics and errors
 * are sent to Dart on the "orvix/exo_player" channel; Dart renders subtitles
 * in the user's chosen style.
 *
 * Privacy: nothing sent to Dart contains a URL, a request header, an info
 * hash or a token. Diagnostics carry only categories, numbers, MIME types,
 * codec strings, decoder names and exception class names.
 */
@OptIn(markerClass = [UnstableApi::class])
class OrvixExoPlayerChannel(
    context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
    activity: Activity? = null,
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val activityRef = WeakReference(activity)
    private val channel = MethodChannel(messenger, "orvix/exo_player")
    private val sessions = HashMap<Long, OrvixExoSession>()
    private var nextId = 1L
    private var keepingScreenOn = false

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
                    textDisabled = call.argument<Boolean>("textDisabled") ?: false,
                    startMs = number(call, "startMs") ?: 0L,
                    onPlayingChanged = { updateKeepScreenOn() },
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
                    updateKeepScreenOn()
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
                error::class.java.simpleName,
                null,
            )
        }
    }

    /**
     * Keeps the display awake while any Orvix ExoPlayer is playing, as the
     * MPV player does, so an Android TV screensaver or a phone's screen
     * timeout never interrupts a film. Paused or closed players release it.
     */
    private fun updateKeepScreenOn() {
        val playing = sessions.values.any { it.isPlayingNow() }
        if (playing == keepingScreenOn) return
        val window = activityRef.get()?.window ?: return
        keepingScreenOn = playing
        if (playing) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    fun releaseAll() {
        for (session in sessions.values) session.release()
        sessions.clear()
        updateKeepScreenOn()
    }

    private fun number(call: MethodCall, key: String): Long? =
        (call.argument<Any>(key) as? Number)?.toLong()
}

/**
 * Counts network transfer milestones on Media3's loader threads. Read by the
 * main-thread ticker, so the Dart side can tell "no connection yet" from
 * "connected, data arriving" from "data arriving, waiting on the decoder".
 */
@OptIn(markerClass = [UnstableApi::class])
private class TransferStats : TransferListener {
    val bytes = AtomicLong(0L)
    val connections = AtomicInteger(0)

    @Volatile var lastHttpStatus: Int = -1

    @Volatile var contentType: String? = null

    @Volatile var acceptsRanges: Boolean? = null

    @Volatile var firstByteAtMs: Long = -1L

    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        connections.incrementAndGet()
        // Diagnostics only: never let them break opening the stream.
        try {
            val http = source as? HttpDataSource ?: return
            lastHttpStatus = http.responseCode
            val headers = http.responseHeaders
            contentType = header(headers, "Content-Type")?.substringBefore(';')?.trim()?.take(64)
            val ranges = header(headers, "Accept-Ranges")
            val contentRange = header(headers, "Content-Range")
            acceptsRanges = when {
                contentRange != null -> true
                ranges != null -> !ranges.equals("none", ignoreCase = true)
                else -> acceptsRanges
            }
        } catch (_: Throwable) {
        }
    }

    override fun onBytesTransferred(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
        bytesTransferred: Int,
    ) {
        if (bytes.getAndAdd(bytesTransferred.toLong()) == 0L && bytesTransferred > 0) {
            firstByteAtMs = SystemClock.elapsedRealtime()
        }
    }

    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

    private fun header(headers: Map<String?, List<String>?>, name: String): String? {
        for ((key, values) in headers) {
            if (key != null && key.equals(name, ignoreCase = true)) return values?.firstOrNull()
        }
        return null
    }
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
    textDisabled: Boolean,
    startMs: Long,
    private val onPlayingChanged: () -> Unit,
) : Player.Listener, TextureRegistry.SurfaceProducer.Callback {
    private val main = Handler(Looper.getMainLooper())
    private val subtitleOffsetUs = AtomicLong(0L)
    private val transfer = TransferStats()
    private val createdAtMs = SystemClock.elapsedRealtime()
    private var released = false
    private var needsSurface = false
    private var lastTracks: Tracks = Tracks.EMPTY
    private var firstFrameAtMs = -1L
    private var loadErrors = 0
    private var droppedFrames = 0L

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

    /**
     * Media3 analytics, kept separate from the Player.Listener callbacks.
     * Declared before init so it exists when the player is built.
     */
    private val analytics = object : AnalyticsListener {

        override fun onLoadError(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
            error: IOException,
            wasCanceled: Boolean,
        ) {
            loadErrors++
            // Media3 retries these; they are only diagnostics unless they end
            // in onPlayerError. Report the first few, then every tenth.
            if (loadErrors <= 3 || loadErrors % 10 == 0) {
                diag(
                    "loadError",
                    mapOf(
                        "count" to loadErrors,
                        "error" to error::class.java.simpleName,
                        "httpStatus" to (error as? HttpDataSource.InvalidResponseCodeException)?.responseCode,
                        "canceled" to wasCanceled,
                    )
                )
            }
        }

        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            diag("videoDecoder", mapOf("name" to decoderName, "initMs" to initializationDurationMs))
        }

        override fun onAudioDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            diag("audioDecoder", mapOf("name" to decoderName, "initMs" to initializationDurationMs))
        }

        override fun onVideoInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            diag(
                "videoFormat",
                mapOf(
                    "mime" to format.sampleMimeType,
                    "codecs" to format.codecs,
                    "width" to format.width,
                    "height" to format.height,
                    "frameRate" to format.frameRate.toDouble(),
                    "pixelRatio" to format.pixelWidthHeightRatio.toDouble(),
                )
            )
        }

        override fun onAudioInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            diag(
                "audioFormat",
                mapOf(
                    "mime" to format.sampleMimeType,
                    "codecs" to format.codecs,
                    "channels" to format.channelCount,
                    "sampleRate" to format.sampleRate,
                )
            )
        }

        override fun onRenderedFirstFrame(
            eventTime: AnalyticsListener.EventTime,
            output: Any,
            renderTimeMs: Long,
        ) {
            if (firstFrameAtMs >= 0L) return
            firstFrameAtMs = SystemClock.elapsedRealtime() - createdAtMs
            diag("firstFrame", mapOf("atMs" to firstFrameAtMs))
            sendState()
        }

        override fun onDroppedVideoFrames(
            eventTime: AnalyticsListener.EventTime,
            droppedFrames: Int,
            elapsedMs: Long,
        ) {
            this@OrvixExoSession.droppedFrames += droppedFrames
        }

        override fun onVideoCodecError(eventTime: AnalyticsListener.EventTime, videoCodecError: Exception) {
            diag("videoCodecError", mapOf("error" to videoCodecError::class.java.simpleName))
        }

        override fun onAudioCodecError(eventTime: AnalyticsListener.EventTime, audioCodecError: Exception) {
            diag("audioCodecError", mapOf("error" to audioCodecError::class.java.simpleName))
        }

        override fun onAudioSinkError(eventTime: AnalyticsListener.EventTime, audioSinkError: Exception) {
            diag("audioSinkError", mapOf("error" to audioSinkError::class.java.simpleName))
        }
    }

    init {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("Orvix")
            .setConnectTimeoutMs(if (patientStartup) 30_000 else 15_000)
            .setReadTimeoutMs(if (patientStartup) 60_000 else 20_000)
            .setDefaultRequestProperties(headers)
            .setTransferListener(transfer)
        // file:// and content:// URIs are opened directly; http(s) goes
        // through the configured HTTP stack above.
        val dataSources = DefaultDataSource.Factory(context, http)
        val mediaSources = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(dataSources)
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
            .setHandleAudioBecomingNoisy(true)
            .build()
        // Movie audio attributes without audio-focus handling: a focus
        // denial must never hold back the first frame.
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            false,
        )
        try {
            // Keeps Wi-Fi at full speed while a stream plays.
            player.setWakeMode(C.WAKE_MODE_NETWORK)
        } catch (_: Throwable) {
        }
        val params = player.trackSelectionParameters.buildUpon()
        if (!preferredTextLanguage.isNullOrBlank()) {
            params.setPreferredTextLanguage(preferredTextLanguage)
        }
        if (!preferredAudioLanguage.isNullOrBlank()) {
            params.setPreferredAudioLanguage(preferredAudioLanguage)
        }
        if (textDisabled) {
            params.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        }
        player.trackSelectionParameters = params.build()
        player.addListener(this)
        player.addAnalyticsListener(analytics)

        producer.setCallback(this)
        val surface = producer.getSurface()
        player.setVideoSurface(surface)
        needsSurface = surface == null

        player.setMediaItem(MediaItem.fromUri(url), startMs.coerceAtLeast(0L))
        player.playWhenReady = true
        player.prepare()
        main.post(ticker)
        diag("created", mapOf("patient" to patientStartup, "resumeMs" to startMs))
    }

    fun isPlayingNow(): Boolean = !released && player.isPlaying

    override fun onSurfaceAvailable() {
        if (released || !needsSurface) return
        player.setVideoSurface(producer.getSurface())
        needsSurface = false
        diag("surface", mapOf("state" to "available"))
    }

    override fun onSurfaceCleanup() {
        if (released) return
        player.setVideoSurface(null)
        needsSurface = true
        diag("surface", mapOf("state" to "cleanup"))
    }

    fun setSubtitleOffsetMs(offsetMs: Long) {
        subtitleOffsetUs.set(offsetMs * 1000L)
    }

    /**
     * Selects one track. A negative [group] turns subtitles off (text) or
     * returns audio to Media3's automatic choice (audio).
     */
    fun selectTrack(type: String, group: Int, track: Int) {
        val trackType = if (type == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
        val builder = player.trackSelectionParameters.buildUpon()
        if (group < 0) {
            builder.clearOverridesOfType(trackType)
            if (trackType == C.TRACK_TYPE_TEXT) {
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

    override fun onPlaybackStateChanged(playbackState: Int) {
        diag("state", mapOf("state" to playbackState))
        sendState()
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        sendState()
        onPlayingChanged()
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        var width = videoSize.width
        val height = videoSize.height
        if (width <= 0 || height <= 0) return
        val ratio = videoSize.pixelWidthHeightRatio
        if (ratio > 0f && ratio != 1f) width = maxOf(1, Math.round(width * ratio))
        val rotation = if (handlesCropAndRotation) 0 else (player.videoFormat?.rotationDegrees ?: 0)
        send(
            mapOf(
                "event" to "video",
                "width" to width,
                "height" to height,
                "rotation" to rotation,
                "codedWidth" to videoSize.width,
                "pixelRatio" to ratio.toDouble(),
            )
        )
    }

    override fun onTracksChanged(tracks: Tracks) {
        lastTracks = tracks
        val list = ArrayList<Map<String, Any?>>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            val type = when (group.type) {
                C.TRACK_TYPE_AUDIO -> "audio"
                C.TRACK_TYPE_TEXT -> "text"
                C.TRACK_TYPE_VIDEO -> "video"
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
                        "sampleRate" to format.sampleRate,
                        "width" to format.width,
                        "height" to format.height,
                        "frameRate" to format.frameRate.toDouble(),
                        "bitrate" to format.bitrate,
                        "selected" to group.isTrackSelected(trackIndex),
                        "supported" to group.isTrackSupported(trackIndex),
                        "support" to supportName(group.getTrackSupport(trackIndex)),
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
        var top = false
        for (cue in cueGroup.cues) {
            val text = cue.text?.toString()?.trim()
            if (!text.isNullOrEmpty()) {
                lines.add(text)
                // Signs and captions the file places in the upper part of the
                // picture keep that placement.
                if (cue.lineType == Cue.LINE_TYPE_FRACTION &&
                    cue.line != Cue.DIMEN_UNSET &&
                    cue.line < 0.4f
                ) {
                    top = true
                }
            }
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
        send(mapOf("event" to "cues", "text" to lines, "bitmaps" to bitmaps, "top" to top))
    }

    override fun onPlayerError(error: PlaybackException) {
        val causes = ArrayList<String>()
        var httpStatus: Int? = null
        var decoderMime: String? = null
        var cause: Throwable? = error.cause
        while (cause != null && causes.size < 6) {
            causes.add(cause::class.java.simpleName)
            if (cause is HttpDataSource.InvalidResponseCodeException) {
                httpStatus = cause.responseCode
            }
            if (cause is MediaCodecRenderer.DecoderInitializationException) {
                decoderMime = cause.mimeType
            }
            if (cause.cause === cause) break
            cause = cause.cause
        }
        val exo = error as? ExoPlaybackException
        val rendererError = exo != null && exo.type == ExoPlaybackException.TYPE_RENDERER
        val rendererFormat = if (rendererError) exo?.rendererFormat else null
        send(
            mapOf(
                "event" to "error",
                "code" to error.errorCodeName,
                "codeNumber" to error.errorCode,
                // Media3's message can carry request details; only the code
                // name crosses to Dart.
                "message" to error.errorCodeName,
                "cause" to causes.joinToString(" > "),
                "causes" to causes,
                "httpStatus" to httpStatus,
                "errorType" to when (exo?.type) {
                    ExoPlaybackException.TYPE_SOURCE -> "source"
                    ExoPlaybackException.TYPE_RENDERER -> "renderer"
                    ExoPlaybackException.TYPE_UNEXPECTED -> "unexpected"
                    ExoPlaybackException.TYPE_REMOTE -> "remote"
                    else -> "unknown"
                },
                "rendererMime" to (rendererFormat?.sampleMimeType ?: decoderMime),
                "rendererCodecs" to rendererFormat?.codecs,
                "rendererSupport" to if (rendererError && exo != null) {
                    supportName(exo.rendererFormatSupport)
                } else {
                    null
                },
                "bytesLoaded" to transfer.bytes.get(),
                "lastHttpStatus" to transfer.lastHttpStatus,
                "atMs" to (SystemClock.elapsedRealtime() - createdAtMs),
            )
        )
        sendState()
        onPlayingChanged()
    }

    private fun diag(kind: String, detail: Map<String, Any?>) {
        val payload = HashMap<String, Any?>(detail)
        payload["event"] = "diag"
        payload["kind"] = kind
        payload["atMs"] = payload["atMs"] ?: (SystemClock.elapsedRealtime() - createdAtMs)
        send(payload)
    }

    private fun supportName(support: Int): String = when (support) {
        C.FORMAT_HANDLED -> "handled"
        C.FORMAT_EXCEEDS_CAPABILITIES -> "exceedsCapabilities"
        C.FORMAT_UNSUPPORTED_DRM -> "unsupportedDrm"
        C.FORMAT_UNSUPPORTED_SUBTYPE -> "unsupportedSubtype"
        else -> "unsupportedType"
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
                "loading" to player.isLoading,
                "bytesLoaded" to transfer.bytes.get(),
                "connections" to transfer.connections.get(),
                "httpStatus" to transfer.lastHttpStatus,
                "contentType" to transfer.contentType,
                "acceptsRanges" to transfer.acceptsRanges,
                "firstByteMs" to if (transfer.firstByteAtMs < 0L) -1L else transfer.firstByteAtMs - createdAtMs,
                "firstFrameMs" to firstFrameAtMs,
                "droppedFrames" to droppedFrames,
                "loadErrors" to loadErrors,
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
        diag("released", emptyMap())
        released = true
        main.removeCallbacks(ticker)
        player.removeListener(this)
        player.removeAnalyticsListener(analytics)
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
