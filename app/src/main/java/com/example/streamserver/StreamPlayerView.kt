package com.example.streamserver

import android.content.Context
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * On-screen viewer: subscribes to the local [StreamRelay] and decodes the
 * H.264 stream with MediaCodec straight onto its surface. Works down to
 * API 19 (the deprecated input-buffer array path is kept for pre-21).
 */
class StreamPlayerView(context: Context) : SurfaceView(context),
    SurfaceHolder.Callback, StreamRelay.Sink {

    private class Frame(val flags: Int, val ptsMs: Long, val payload: ByteArray)

    /** Elapsed-realtime of the last rendered frame (0 = nothing yet). */
    @Volatile var lastFrameMs = 0L
        private set

    /** Called on a background thread when the video size becomes known. */
    @Volatile var onVideoSize: ((Int, Int) -> Unit)? = null

    private val queue = ArrayBlockingQueue<Frame>(90)
    @Volatile private var gen = 0
    @Volatile private var surfaceReady = false
    private var relay: StreamRelay? = null

    init {
        holder.addCallback(this)
    }

    fun play(relay: StreamRelay, key: String) {
        stopPlayback()
        this.relay = relay
        lastFrameMs = 0L
        relay.subscribe(key, this)
        val g = ++gen
        thread(isDaemon = true, name = "player-decode") { decodeLoop(g) }
    }

    fun stopPlayback() {
        gen++
        relay?.unsubscribe(this)
        queue.clear()
        lastFrameMs = 0L
    }

    // The relay's dispatch thread: drop the oldest when the decoder lags.
    override fun onFrame(flags: Int, ptsMs: Long, payload: ByteArray) {
        // The native fallback player is video-only; sound (flag bit1) plays
        // in the WebView/browser viewers.
        if (flags and 2 != 0) return
        if (queue.remainingCapacity() == 0) queue.poll()
        queue.offer(Frame(flags, ptsMs, payload))
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
    }

    override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        gen++ // the decoder must not touch a dead surface
    }

    // --------------------------------------------------------------- decode

    private fun decodeLoop(g: Int) {
        while (g == gen) {
            // 1. Wait for a keyframe that carries SPS/PPS.
            var first: Frame? = null
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            while (g == gen) {
                val f = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                if (f.flags and 1 == 0) continue
                for (nal in splitNals(f.payload)) {
                    when (nal[0].toInt() and 0x1f) {
                        7 -> sps = nal
                        8 -> pps = nal
                    }
                }
                if (sps != null && pps != null) {
                    first = f
                    break
                }
            }
            if (g != gen || first == null) return
            while (g == gen && !surfaceReady) SystemClock.sleep(100)
            if (g != gen) return

            // 2. Decode until the stream or the codec breaks.
            val dims = spsDimensions(sps!!)
            onVideoSize?.invoke(dims.first, dims.second)
            var codec: MediaCodec? = null
            try {
                codec = MediaCodec.createDecoderByType("video/avc")
                val start = byteArrayOf(0, 0, 0, 1)
                val fmt = MediaFormat.createVideoFormat(
                    "video/avc", dims.first, dims.second
                ).apply {
                    setByteBuffer("csd-0", ByteBuffer.wrap(start + sps))
                    setByteBuffer("csd-1", ByteBuffer.wrap(start + pps!!))
                }
                codec.configure(fmt, holder.surface, null, 0)
                codec.start()
                @Suppress("DEPRECATION")
                val legacyIn = if (Build.VERSION.SDK_INT < 21) codec.inputBuffers else null
                val info = MediaCodec.BufferInfo()
                var pending: Frame? = first
                while (g == gen) {
                    val f = pending ?: queue.poll(200, TimeUnit.MILLISECONDS)
                    pending = null
                    if (f != null) {
                        val idx = codec.dequeueInputBuffer(50_000)
                        if (idx >= 0) {
                            val buf = if (legacyIn != null) legacyIn[idx]
                            else codec.getInputBuffer(idx)!!
                            buf.clear()
                            buf.put(f.payload)
                            codec.queueInputBuffer(
                                idx, 0, f.payload.size, f.ptsMs * 1000, 0
                            )
                        } else {
                            pending = f // no input slot yet, retry the frame
                        }
                    }
                    while (true) {
                        val oi = codec.dequeueOutputBuffer(info, 0)
                        if (oi >= 0) {
                            codec.releaseOutputBuffer(oi, true)
                            lastFrameMs = SystemClock.elapsedRealtime()
                        } else if (oi != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED &&
                            oi != @Suppress("DEPRECATION")
                            MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED
                        ) {
                            break
                        }
                    }
                }
            } catch (_: Exception) {
                // Codec died (bad data / publisher restart): resync on the
                // next keyframe with fresh SPS/PPS.
            } finally {
                try {
                    codec?.stop()
                } catch (_: Exception) {
                }
                try {
                    codec?.release()
                } catch (_: Exception) {
                }
            }
        }
    }

    // ---------------------------------------------------------------- utils

    private fun splitNals(data: ByteArray): List<ByteArray> {
        val nals = ArrayList<ByteArray>()
        var i = 0
        var start = -1
        while (i + 2 < data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 &&
                (data[i + 2].toInt() == 1 ||
                    (data[i + 2].toInt() == 0 && i + 3 < data.size &&
                        data[i + 3].toInt() == 1))
            ) {
                val skip = if (data[i + 2].toInt() == 1) 3 else 4
                if (start >= 0) nals.add(data.copyOfRange(start, i))
                i += skip
                start = i
            } else {
                i++
            }
        }
        if (start >= 0) nals.add(data.copyOfRange(start, data.size))
        return nals
    }

    /** Coded width/height from the SPS (enough of an exp-Golomb parse). */
    private fun spsDimensions(sps: ByteArray): Pair<Int, Int> {
        return try {
            val rbsp = ArrayList<Int>()
            for (i in 1 until sps.size) {
                if (i >= 3 && sps[i].toInt() == 3 &&
                    sps[i - 1].toInt() == 0 && sps[i - 2].toInt() == 0
                ) continue
                rbsp.add(sps[i].toInt() and 0xff)
            }
            var bit = 0
            fun u(n: Int): Int {
                var v = 0
                repeat(n) {
                    v = (v shl 1) or ((rbsp[bit shr 3] shr (7 - (bit and 7))) and 1)
                    bit++
                }
                return v
            }
            fun ue(): Int {
                var z = 0
                while (u(1) == 0 && z < 32) z++
                return (1 shl z) - 1 + u(z)
            }
            fun se(): Int {
                val k = ue()
                return if (k and 1 == 1) (k + 1) shr 1 else -(k shr 1)
            }
            val profile = u(8)
            u(8); u(8); ue()
            if (profile in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128)) {
                val chroma = ue()
                if (chroma == 3) u(1)
                ue(); ue(); u(1)
                if (u(1) == 1) {
                    for (i in 0 until if (chroma != 3) 8 else 12) {
                        if (u(1) == 1) {
                            var last = 8
                            var next = 8
                            val size = if (i < 6) 16 else 64
                            for (j in 0 until size) {
                                if (next != 0) next = (last + se() + 256) % 256
                                if (next != 0) last = next
                            }
                        }
                    }
                }
            }
            ue()
            when (ue()) {
                0 -> ue()
                1 -> {
                    u(1); se(); se()
                    repeat(ue()) { se() }
                }
            }
            ue(); u(1)
            val wMbs = ue() + 1
            val hMbs = ue() + 1
            val frameMbsOnly = u(1)
            if (frameMbsOnly == 0) u(1)
            u(1)
            var cl = 0; var cr = 0; var ct = 0; var cb = 0
            if (u(1) == 1) {
                cl = ue(); cr = ue(); ct = ue(); cb = ue()
            }
            val w = wMbs * 16 - (cl + cr) * 2
            val h = (2 - frameMbsOnly) * hMbs * 16 -
                (ct + cb) * (if (frameMbsOnly == 1) 2 else 4)
            if (w in 16..4096 && h in 16..4096) w to h else 854 to 480
        } catch (_: Exception) {
            854 to 480
        }
    }
}
