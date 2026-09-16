package com.example.streamserver

import android.util.Base64
import java.io.DataInputStream
import java.io.OutputStream
import java.io.PushbackInputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.concurrent.thread
import kotlin.random.Random

/**
 * H.264 stream relay — the Android twin of node-streaming-server.
 *
 * ONE TCP port serves everything, so a single open/forwarded port crosses
 * firewalls. Standard ports are preferred (8080, 8000, 8888 — an Android
 * app cannot bind below 1024); if all are taken, the previously used port
 * (persisted via [onPortSelected]) and finally a random port from
 * 6500..7500 are tried. Connections are told apart by their first bytes:
 *
 *  Publishers (raw TCP):
 *    "STREAM <key> [token]\n" -> "OK <token>\n" | "BUSY\n" | "BAD\n"
 *    "CHECK <key>\n"          -> "FREE\n" | "BUSY\n" | "BAD\n"
 *    The token is a server-issued device validation key (never shown to
 *    users): a publisher reconnecting with the right token takes its key
 *    back from a stale session instead of getting BUSY.
 *    then frames: u32be payloadLen, u8 flags (bit0 keyframe), u64be ptsMs,
 *    payload = H.264 Annex-B with SPS/PPS prepended to keyframes.
 *
 *  Browsers (HTTP): GET / (viewer page), GET /info (JSON),
 *    GET /ws?key=K (WebSocket; binary messages: u8 flags, u64be pts, payload).
 *
 * The app's own screen subscribes through [subscribe] — the same fan-out
 * path as a WebSocket viewer, without the socket.
 */
class StreamRelay(private val viewerHtml: ByteArray) {

    companion object {
        const val VERSION = "1.4"
        // Most-probably-open ports first; 6500..7500 is the last resort.
        private val STANDARD_PORTS = intArrayOf(8080, 8000, 8888)
        private const val PORT_MIN = 6500
        private const val PORT_MAX = 7500
        private const val MAX_FRAME = 4 * 1024 * 1024
        private const val WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private val KEY_RE = Regex("^[A-Za-z0-9_-]{1,64}$")

        fun isValidKey(key: String): Boolean = KEY_RE.matches(key)
    }

    /** A frame consumer: WS viewers and the on-screen player. */
    interface Sink {
        fun onFrame(flags: Int, ptsMs: Long, payload: ByteArray)
    }

    private class SinkEntry(val sink: Sink) {
        @Volatile var started = false
    }

    private class Stream {
        @Volatile var publisher: Socket? = null
        @Volatile var token = ""
        val sinks = CopyOnWriteArraySet<SinkEntry>()
    }

    /** The single port serving viewers AND publishers (0 = not bound yet). */
    @Volatile var port = 0
        private set
    val viewerPort: Int get() = port
    val streamPort: Int get() = port

    /** Port bound / a live stream appeared or vanished. Any thread. */
    @Volatile var onStateChanged: (() -> Unit)? = null
    var preferredPort = 0
    @Volatile var onPortSelected: ((Int) -> Unit)? = null

    private var server: ServerSocket? = null
    private val streams = ConcurrentHashMap<String, Stream>()

    fun liveKeys(): List<String> =
        streams.filterValues { it.publisher != null }.keys.sorted()

    // ------------------------------------------------------------- lifecycle

    fun start() {
        stop()
        thread(isDaemon = true, name = "relay-bind") {
            val ss = bindPreferred() ?: return@thread
            server = ss
            port = ss.localPort
            if (port != preferredPort) onPortSelected?.invoke(port)
            onStateChanged?.invoke()
            acceptLoop(ss, ::handleConnection)
        }
    }

    fun stop() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        port = 0
    }

    /** Standard ports first, then the sticky one, then randoms in range. */
    private fun bindPreferred(): ServerSocket? {
        val candidates = ArrayList<Int>()
        STANDARD_PORTS.forEach { candidates.add(it) }
        if (preferredPort in 1..65535 && preferredPort !in candidates) {
            candidates.add(preferredPort)
        }
        repeat(200) { candidates.add(Random.nextInt(PORT_MIN, PORT_MAX + 1)) }
        for (p in candidates) {
            try {
                return ServerSocket(p)
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** Sniffs the first bytes: publisher handshake or HTTP. */
    private fun handleConnection(socket: Socket) {
        socket.soTimeout = 15000
        val pin = PushbackInputStream(socket.getInputStream(), 16)
        val head = ByteArray(7)
        var n = 0
        while (n < head.size) {
            val r = pin.read(head, n, head.size - n)
            if (r < 0) break
            n += r
        }
        if (n <= 0) return
        pin.unread(head, 0, n)
        val ins = DataInputStream(pin)
        val lead = String(head, 0, n, Charsets.US_ASCII)
        if (lead.startsWith("STREAM") || lead.startsWith("CHECK")) {
            handlePublisher(socket, ins)
        } else {
            handleHttp(socket, ins)
        }
    }

    private fun acceptLoop(server: ServerSocket, handler: (Socket) -> Unit) {
        while (!server.isClosed) {
            try {
                val socket = server.accept()
                thread(isDaemon = true) {
                    try {
                        handler(socket)
                    } catch (_: Exception) {
                    } finally {
                        try { socket.close() } catch (_: Exception) {}
                    }
                }
            } catch (_: Exception) {
                // Closed server ends the loop.
            }
        }
    }

    // ----------------------------------------------------------- publishers

    private fun stream(key: String): Stream {
        var s = streams[key]
        if (s == null) {
            s = Stream()
            val prev = streams.putIfAbsent(key, s)
            if (prev != null) s = prev
        }
        return s
    }

    private fun gcStream(key: String) {
        val s = streams[key] ?: return
        if (s.publisher == null && s.sinks.isEmpty()) streams.remove(key, s)
    }

    private fun handlePublisher(socket: Socket, ins: DataInputStream) {
        socket.tcpNoDelay = true
        val out = socket.getOutputStream()
        val line = readLine(ins, 512) ?: return
        val m = Regex("^(STREAM|CHECK)\\s+(\\S+)(?:\\s+(\\S+))?$")
            .find(line.trim()) ?: run {
            out.write("BAD\n".toByteArray()); return
        }
        val verb = m.groupValues[1]
        val key = m.groupValues[2]
        val clientToken = m.groupValues[3]
        if (!isValidKey(key)) {
            out.write("BAD\n".toByteArray()); return
        }
        if (clientToken.isNotEmpty() &&
            !clientToken.matches(Regex("^[0-9a-fA-F]{16,64}$"))
        ) {
            out.write("BAD\n".toByteArray()); return
        }
        if (verb == "CHECK") {
            val busy = streams[key]?.publisher != null
            out.write((if (busy) "BUSY\n" else "FREE\n").toByteArray())
            return
        }
        val s = stream(key)
        var replaced: Socket? = null
        synchronized(s) {
            val current = s.publisher
            if (current != null) {
                // The device validation token: the same publisher returning
                // replaces its stale session; a different device stays BUSY.
                if (clientToken.isEmpty() || clientToken != s.token) {
                    out.write("BUSY\n".toByteArray())
                    return
                }
                replaced = current
            }
            if (s.token.isEmpty()) {
                s.token = java.util.UUID.randomUUID().toString().replace("-", "")
            }
            s.publisher = socket
        }
        try {
            replaced?.close()
        } catch (_: Exception) {
        }
        // A (re)starting encoder means new parameters: resync every viewer.
        for (entry in s.sinks) entry.started = false
        // A live publisher pushes ~30 fps; a long-silent one is dead.
        socket.soTimeout = 60000
        out.write("OK ${s.token}\n".toByteArray())
        onStateChanged?.invoke()
        try {
            while (true) {
                val len = ins.readInt()
                if (len <= 0 || len > MAX_FRAME) break
                val flags = ins.readUnsignedByte()
                val pts = ins.readLong()
                val payload = ByteArray(len)
                ins.readFully(payload)
                for (entry in s.sinks) {
                    if (!entry.started) {
                        if (flags and 1 == 0) continue // wait for a keyframe
                        entry.started = true
                    }
                    try {
                        entry.sink.onFrame(flags, pts, payload)
                    } catch (_: Exception) {
                        s.sinks.remove(entry)
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            if (s.publisher === socket) {
                s.publisher = null
                // Viewers stay and resume at the next keyframe.
                for (entry in s.sinks) entry.started = false
                gcStream(key)
                onStateChanged?.invoke()
            }
        }
    }

    // -------------------------------------------------------- local viewers

    private val localEntries = ConcurrentHashMap<Sink, Pair<String, SinkEntry>>()

    fun subscribe(key: String, sink: Sink) {
        unsubscribe(sink)
        val entry = SinkEntry(sink)
        stream(key).sinks.add(entry)
        localEntries[sink] = key to entry
    }

    fun unsubscribe(sink: Sink) {
        val reg = localEntries.remove(sink) ?: return
        streams[reg.first]?.sinks?.remove(reg.second)
        gcStream(reg.first)
    }

    // ------------------------------------------------------------- HTTP / WS

    private fun handleHttp(socket: Socket, ins: DataInputStream) {
        socket.soTimeout = 10000
        val out = socket.getOutputStream()
        val request = readLine(ins, 2048) ?: return
        val headers = HashMap<String, String>()
        while (true) {
            val h = readLine(ins, 2048) ?: return
            if (h.isEmpty()) break
            val idx = h.indexOf(':')
            if (idx > 0) {
                headers[h.substring(0, idx).trim().lowercase()] =
                    h.substring(idx + 1).trim()
            }
        }
        val rm = Regex("^GET\\s+(\\S+)").find(request) ?: return
        val target = rm.groupValues[1]
        val path = target.substringBefore('?')
        val query = target.substringAfter('?', "")

        if (path == "/ws") {
            val key = query.split('&')
                .firstOrNull { it.startsWith("key=") }?.substring(4) ?: ""
            val wsKey = headers["sec-websocket-key"]
            if (!isValidKey(key) || wsKey == null) return
            handleWebSocket(socket, out, ins, key, wsKey)
            return
        }
        when (path) {
            "/", "/index.html" -> {
                writeHttp(out, "200 OK", "text/html; charset=utf-8", viewerHtml)
            }
            "/info" -> {
                val ips = localIps().joinToString(",") { "\"$it\"" }
                val live = liveKeys().joinToString(",") { "\"$it\"" }
                val json = "{\"version\":\"$VERSION\",\"ips\":[$ips]," +
                    "\"viewerPort\":$viewerPort,\"streamPort\":$streamPort," +
                    "\"live\":[$live]}"
                writeHttp(out, "200 OK", "application/json", json.toByteArray())
            }
            else -> writeHttp(out, "404 Not Found", "text/plain", "not found".toByteArray())
        }
    }

    private fun writeHttp(out: OutputStream, status: String, type: String, body: ByteArray) {
        out.write(
            ("HTTP/1.1 $status\r\nContent-Type: $type\r\n" +
                "Content-Length: ${body.size}\r\nCache-Control: no-cache\r\n" +
                "Connection: close\r\n\r\n").toByteArray()
        )
        out.write(body)
        out.flush()
    }

    private fun handleWebSocket(
        socket: Socket, out: OutputStream, ins: DataInputStream,
        key: String, wsKey: String
    ) {
        val accept = Base64.encodeToString(
            MessageDigest.getInstance("SHA-1")
                .digest((wsKey + WS_MAGIC).toByteArray()),
            Base64.NO_WRAP
        )
        out.write(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                "Connection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n").toByteArray()
        )
        out.flush()
        socket.soTimeout = 0
        socket.tcpNoDelay = true

        val sink = object : Sink {
            override fun onFrame(flags: Int, ptsMs: Long, payload: ByteArray) {
                val n = 9 + payload.size
                val header: ByteArray = when {
                    n < 126 -> byteArrayOf(0x82.toByte(), n.toByte())
                    n < 65536 -> byteArrayOf(
                        0x82.toByte(), 126,
                        (n ushr 8).toByte(), n.toByte()
                    )
                    else -> ByteArray(10).also {
                        it[0] = 0x82.toByte(); it[1] = 127
                        for (i in 0..7) it[2 + i] = (n.toLong() ushr (56 - 8 * i)).toByte()
                    }
                }
                synchronized(out) {
                    out.write(header)
                    out.write(flags)
                    for (i in 0..7) out.write(((ptsMs ushr (56 - 8 * i)) and 0xff).toInt())
                    out.write(payload)
                    out.flush()
                }
            }
        }
        val entry = SinkEntry(sink)
        val s = stream(key)
        s.sinks.add(entry)
        try {
            // Client frame loop: answers pings, honors close, ignores data.
            while (true) {
                val b0 = ins.read()
                if (b0 < 0) break
                val opcode = b0 and 0x0f
                val b1 = ins.read()
                if (b1 < 0) break
                var len = (b1 and 0x7f).toLong()
                if (len == 126L) {
                    len = ((ins.read() shl 8) or ins.read()).toLong()
                } else if (len == 127L) {
                    len = 0
                    repeat(8) { len = (len shl 8) or ins.read().toLong() }
                }
                val mask = if (b1 and 0x80 != 0) {
                    ByteArray(4).also { ins.readFully(it) }
                } else null
                if (len > 65536) break
                val payload = ByteArray(len.toInt())
                ins.readFully(payload)
                if (mask != null) {
                    for (i in payload.indices) {
                        payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                    }
                }
                if (opcode == 8) break
                if (opcode == 9) {
                    synchronized(out) {
                        out.write(0x8a)
                        out.write(payload.size)
                        out.write(payload)
                        out.flush()
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            s.sinks.remove(entry)
            gcStream(key)
        }
    }

    // ---------------------------------------------------------------- utils

    private fun readLine(ins: DataInputStream, max: Int): String? {
        val sb = StringBuilder()
        while (sb.length < max) {
            val c = ins.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
        }
        return null
    }

    fun localIps(): List<String> = try {
        java.net.NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<java.net.Inet4Address>()
            .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            .sortedByDescending { it.isSiteLocalAddress }
            .mapNotNull { it.hostAddress }
            .distinct()
            .toList()
    } catch (_: Exception) {
        emptyList()
    }
}
