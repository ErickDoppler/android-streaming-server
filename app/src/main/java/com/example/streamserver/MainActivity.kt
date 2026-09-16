package com.example.streamserver

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * Streaming Server for Android — the same relay as node-streaming-server
 * (publisher port + viewer page port, both sticky in 6500..7500), plus the
 * device's own screen as a viewer.
 *
 * On API 21+ the screen simply shows the served viewer page in a WebView
 * (identical UI and behavior to a browser: KEY + CONNECT, catalog, MSE
 * video). On API 19/20 the WebView cannot play MSE video, so a native UI
 * with a MediaCodec player provides the same functions.
 */
class MainActivity : Activity() {

    private companion object {
        const val GREEN = 0xFF00FF46.toInt()
        const val DIM = 0xFF0A8F33.toInt()
        const val AMBER = 0xFFFFB300.toInt()
        const val RED = 0xFFFF4040.toInt()
    }

    private val prefs by lazy { getSharedPreferences("stream_server", MODE_PRIVATE) }
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var relay: StreamRelay
    private var endpoints: TextView? = null
    private var status: TextView? = null
    private var catalogBox: LinearLayout? = null
    private var keyInput: EditText? = null
    private var player: StreamPlayerView? = null
    private var playerFrame: LinearLayout? = null
    private var webView: WebView? = null
    private var pageLoaded = false

    private var connectedKey = ""
    private var videoW = 16
    private var videoH = 9

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        relay = StreamRelay(assets.open("index.html").readBytes())
        // "viewer_port" is the pre-V1.1 two-port preference key.
        relay.preferredPort = prefs.getInt("port", prefs.getInt("viewer_port", 0))
        relay.onPortSelected = { p -> prefs.edit().putInt("port", p).apply() }

        if (Build.VERSION.SDK_INT >= 21) {
            setupWebUi()
        } else {
            setupNativeUi()
        }
        relay.start()
    }

    // HTML fullscreen inside the WebView (video double-tap): the page's
    // requestFullscreen only works when the app hosts the custom view.
    private var fullscreenView: android.view.View? = null
    private var fullscreenCallback: android.webkit.WebChromeClient.CustomViewCallback? = null

    /** API 21+: the app IS the served viewer page. */
    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebUi() {
        val wv = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true // the catalog lives in localStorage
            settings.mediaPlaybackRequiresUserGesture = false
        }
        wv.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onShowCustomView(
                view: android.view.View,
                callback: android.webkit.WebChromeClient.CustomViewCallback
            ) {
                if (fullscreenView != null) {
                    callback.onCustomViewHidden()
                    return
                }
                fullscreenView = view
                fullscreenCallback = callback
                (window.decorView as ViewGroup).addView(
                    view, ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                )
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility =
                    android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or
                    android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            }

            override fun onHideCustomView() {
                val v = fullscreenView ?: return
                (window.decorView as ViewGroup).removeView(v)
                fullscreenView = null
                fullscreenCallback?.onCustomViewHidden()
                fullscreenCallback = null
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = 0
            }
        }
        webView = wv
        setContentView(wv)
        relay.onStateChanged = {
            runOnUiThread {
                if (!pageLoaded && relay.viewerPort != 0) {
                    pageLoaded = true
                    wv.loadUrl("http://127.0.0.1:${relay.viewerPort}/")
                }
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (fullscreenView != null) {
            webView?.webChromeClient?.onHideCustomView()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    /** API 19/20: native UI with a MediaCodec player. */
    private fun setupNativeUi() {
        val dp = resources.displayMetrics.density

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            val pad = (12 * dp).toInt()
            setPadding(pad, pad, pad, pad)
        }

        val title = text(20f, GREEN).apply {
            text = "STREAMING SERVER V${StreamRelay.VERSION}"
            setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
        }
        val endpointsView = text(12f, DIM).apply { text = "STARTING SERVER..." }
        endpoints = endpointsView

        val keyIn = EditText(this).apply {
            hint = "stream key"
            setHintTextColor(DIM)
            setTextColor(GREEN)
            typeface = Typeface.MONOSPACE
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSingleLine = true
        }
        keyInput = keyIn
        val connectBtn = button("CONNECT") { connectTo(keyIn.text.toString().trim()) }
        val keyRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text(14f, GREEN).apply { text = "KEY " })
            addView(keyIn, LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(connectBtn)
        }

        val statusView = text(13f, DIM)
        status = statusView

        val catalogHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text(12f, DIM).apply { text = "STREAMING CATALOG  " })
            addView(button("CLEAR") {
                prefs.edit().remove("catalog").apply()
                renderCatalog()
            })
        }
        val catalog = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        catalogBox = catalog

        val pl = StreamPlayerView(this)
        player = pl
        pl.onVideoSize = { w, h ->
            runOnUiThread {
                videoW = w
                videoH = h
                fitPlayer()
            }
        }
        // Letterboxed video area filling the remaining screen.
        val frame = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(pl, LinearLayout.LayoutParams(1, 1))
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitPlayer() }
        }
        playerFrame = frame

        root.addView(title)
        root.addView(endpointsView)
        root.addView(keyRow)
        root.addView(statusView)
        root.addView(catalogHead)
        root.addView(catalog, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(frame, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        renderCatalog()

        relay.onStateChanged = { runOnUiThread { updateEndpoints() } }
        mainHandler.post(statusTick)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(statusTick)
        player?.stopPlayback()
        relay.stop()
        super.onDestroy()
    }

    // ------------------------------------------------------------------- UI

    private fun text(sizeSp: Float, color: Int): TextView = TextView(this).apply {
        textSize = sizeSp
        setTextColor(color)
        typeface = Typeface.MONOSPACE
    }

    private fun button(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 13f
            setTextColor(GREEN)
            typeface = Typeface.MONOSPACE
            setBackgroundColor(0xFF002A0D.toInt())
            setOnClickListener { onClick() }
        }

    private fun updateEndpoints() {
        val view = endpoints ?: return
        val ips = relay.localIps()
        if (relay.streamPort == 0 || ips.isEmpty()) {
            view.text = "STARTING SERVER..."
            return
        }
        view.text =
            "STREAM CLIENTS CONNECT TO:  " +
            ips.joinToString("   ") { "$it:${relay.streamPort}" } +
            "\nVIEWER PAGE:  " +
            ips.joinToString("   ") { "http://$it:${relay.viewerPort}" }
    }

    private fun fitPlayer() {
        val frame = playerFrame ?: return
        val pl = player ?: return
        val fw = frame.width
        val fh = frame.height
        if (fw <= 0 || fh <= 0) return
        var w = fw
        var h = w * videoH / videoW
        if (h > fh) {
            h = fh
            w = h * videoW / videoH
        }
        val lp = pl.layoutParams
        if (lp.width != w || lp.height != h) {
            lp.width = w
            lp.height = h
            pl.layoutParams = lp
        }
    }

    // -------------------------------------------------------------- catalog

    private fun catalog(): List<String> =
        (prefs.getString("catalog", "") ?: "").split(',').filter { it.isNotEmpty() }

    private fun renderCatalog() {
        val box = catalogBox ?: return
        box.removeAllViews()
        val dp = resources.displayMetrics.density
        for (k in catalog()) {
            box.addView(text(14f, GREEN).apply {
                text = k
                paintFlags = paintFlags or android.graphics.Paint.UNDERLINE_TEXT_FLAG
                setPadding(0, (4 * dp).toInt(), (14 * dp).toInt(), (4 * dp).toInt())
                setOnClickListener {
                    keyInput?.setText(k)
                    connectTo(k)
                }
            })
        }
    }

    // ------------------------------------------------------------ streaming

    private fun connectTo(key: String) {
        if (!StreamRelay.isValidKey(key)) {
            Toast.makeText(
                this, "Invalid key (letters, digits, - and _)", Toast.LENGTH_SHORT
            ).show()
            return
        }
        val list = ArrayList(catalog())
        list.remove(key)
        list.add(0, key)
        prefs.edit().putString("catalog", list.take(50).joinToString(",")).apply()
        renderCatalog()
        try {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                .hideSoftInputFromWindow(keyInput?.windowToken, 0)
        } catch (_: Exception) {
        }
        connectedKey = key
        player?.play(relay, key)
        status?.setTextColor(AMBER)
        status?.text = "WAITING FOR STREAM — $key"
    }

    private val statusTick = object : Runnable {
        override fun run() {
            val pl = player
            if (connectedKey.isNotEmpty() && pl != null) {
                val fresh = pl.lastFrameMs != 0L &&
                    SystemClock.elapsedRealtime() - pl.lastFrameMs < 2500
                if (fresh) {
                    status?.setTextColor(GREEN)
                    status?.text = "LIVE — $connectedKey"
                } else {
                    status?.setTextColor(AMBER)
                    status?.text = "WAITING FOR STREAM — $connectedKey"
                }
            }
            mainHandler.postDelayed(this, 1000L)
        }
    }
}
