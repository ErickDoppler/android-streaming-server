# android-streaming-server

A live H.264 video relay that **runs on an Android phone or tablet** — no
server, no cloud, no account. One device becomes the hub: encoders push a
stream into it over plain TCP, and anyone on the same network watches in a
browser, or on the device's own screen.

It is the Android twin of [`node-streaming-server`](#related-projects) and
speaks exactly the same wire protocol, so the same publishers work against
either one.

```
 ┌──────────────┐   TCP: STREAM <key>    ┌─────────────────────┐
 │  publisher   │ ─────────────────────▶ │   Android device    │
 │ (camera app, │   H.264 frames         │  android-streaming- │
 │  screen cap) │                        │       server        │
 └──────────────┘                        │                     │
                                         │  ONE TCP port for   │
 ┌──────────────┐   http://ip:port       │  everything         │
 │   browser    │ ◀───── viewer page ─── │                     │
 │  (any LAN    │   WebSocket /ws?key=   │  + the device's own │
 │   device)    │ ◀───── frames ──────── │    screen is a      │
 └──────────────┘                        │    viewer too       │
                                         └─────────────────────┘
```

**Version 1.4** · `minSdk 19` (Android 4.4 KitKat) · `targetSdk 35` ·
Kotlin, **zero third-party dependencies**.

---

## How to run it

Get the code, then follow the three steps for your platform. Nothing is
installed system-wide — no Android Studio, no `sudo`.

```bash
git clone https://github.com/ErickDoppler/android-streaming-server.git
cd android-streaming-server
```

### Windows

**1. Run `download-tools.cmd`** — fetches a JDK 17 and the Android SDK into
`tools\`. A few hundred MB, once.

```bash
download-tools.cmd
```

**2. Run `build.cmd`** — builds `dist\streaming-server-1.4-debug.apk`.

```bash
build.cmd
```

**3. Run `build.cmd --install`** to deploy it. Connect the Android device by
USB with **USB debugging** turned on first; this installs the APK and starts
the app on the device.

```bash
build.cmd --install
```

### Linux / macOS

**1. Run `./download-tools.sh`** — fetches a JDK 17 and the Android SDK into
`tools/`. A few hundred MB, once.

```bash
./download-tools.sh
```

**2. Run `./build.sh`** — builds `dist/streaming-server-1.4-debug.apk`.

```bash
./build.sh
```

**3. Run `./build.sh --install`** to deploy it. Connect the Android device by
USB with **USB debugging** turned on first; this installs the APK and starts
the app on the device.

```bash
./build.sh --install
```

### Then

The app shows the address it is serving on, for example
`http://192.168.1.42:8080`. Open that in a browser on any device on the same
network, or watch on the device's own screen. Point a publisher at
`192.168.1.42:8080`, type the same stream key in the viewer, press
**CONNECT**.

> **No device attached?** Skip step 3 — `build.cmd` / `./build.sh` still
> produces the APK in `dist/`. Copy it to the device and tap it to install
> (Android will ask you to allow installs from that source).

See [Using it](#using-it) for what the app does once it is running, and
[Building](#building) for the build options in full.

---

## Why it exists

Getting a camera feed from one device onto another usually means an RTMP
server, a cloud relay, or a subscription. This is a ~1,100-line app that does
the useful part locally:

- **One TCP port serves everything.** Publishers and browsers arrive on the
  same socket and are told apart by their first bytes. One port to open, one
  port to forward — no juggling.
- **Old hardware is a first-class target.** `minSdk 19` means a forgotten 2013
  tablet becomes a streaming hub. On API 21+ the app shows the served viewer
  page in a WebView; on API 19/20, where WebView cannot play MSE video, it
  falls back to a native `MediaCodec` player with the same functions.
- **Nothing to install on the viewer side.** Any browser on the LAN.

---

## Using it

1. **Launch the app** on the Android device. It picks a port and shows two
   lines:

   ```
   STREAM CLIENTS CONNECT TO:  192.168.1.42:8080
   VIEWER PAGE:                http://192.168.1.42:8080
   ```

   The port is sticky: it prefers `8080`, then `8000`, then `8888`, then the
   port it used last time, and only then a random one in `6500..7500`. (An
   Android app cannot bind below 1024, so port 80 is not an option.)

2. **Point a publisher at it.** Any client that speaks the
   [wire protocol](#wire-protocol) works — for example the companion
   `android-stream-publisher` app. It needs the `host:port` above and a
   **stream key**: any string of letters, digits, `-` and `_`, up to 64
   characters. The key is a channel name, not a password.

3. **Watch.** Either on the device's own screen, or from any browser on the
   network at `http://<device-ip>:<port>`. Type the same key, press
   **CONNECT**.

### The viewer page

The page is served from the app itself (`app/src/main/assets/index.html`) and
carries no external resources, so it works with no internet access.

| Action | What it does |
| --- | --- |
| **CONNECT** | subscribes to a key; playback starts at the next keyframe |
| **STREAMING CATALOG** | keys you have used before, one click to reconnect — kept in `localStorage`, **CLEAR** forgets them |
| **double-click / double-tap the video** | fullscreen (with a fallback for browsers without the Fullscreen API) |
| **long-press the video** | rotates the picture 90° — for a publisher mounted sideways |
| **click the title** | cycles the colour scheme |
| **the video's own controls** | audio starts **muted**; unmute there |

Video arrives as raw H.264 and is remuxed to fragmented MP4 *in JavaScript*
before being handed to Media Source Extensions — that is why no player
library is needed. AAC audio, when the publisher sends it, is remuxed the
same way.

### Streams and keys

- A key is **claimed by one publisher at a time**. A second publisher on a
  live key is answered `BUSY`.
- When a publisher reconnects — a dropped Wi-Fi, an app restart — it presents
  the **token** the server issued on its first `OK`. A matching token takes
  the key back from the stale session; a different device still gets `BUSY`.
  The token is a device-validation value, never shown to users.
- Viewers are never disconnected by this. When a publisher drops and returns,
  every viewer resyncs at the next keyframe on its own.
- Any number of viewers may watch one key.

---

## Building

### What the build needs

| | |
| --- | --- |
| **JDK** | 17 – 23. The Android Gradle plugin 8.7.3 needs 17 or newer; Gradle 8.11.1 refuses to start on anything newer than 23. |
| **Android SDK** | `platforms;android-35`, `build-tools;35.0.0`, `platform-tools` |
| **Gradle** | 8.11.1 — fetched automatically by the `gradlew` wrapper |

### `download-tools.cmd` / `download-tools.sh`

Fetches all of the above into `tools/` and writes `local.properties` so
Gradle can find the SDK.

```
download-tools.cmd            reuse a usable JDK / SDK already on this
                              machine; download only what is missing
download-tools.cmd --force    ignore what is installed and download private
                              copies into tools/
```

Nothing is installed system-wide, nothing touches the registry or `PATH`.
The JDK comes from [Eclipse Temurin](https://adoptium.net) and the SDK from
`dl.google.com`, both over HTTPS, and both are checked against the SHA
checksums those projects publish — a mismatch aborts with nothing installed.

Expect a few hundred MB on the first run. It is idempotent: run it again and
it will tell you everything is already in place.

### `build.cmd` / `build.sh`

```
build.cmd                 debug APK — signed with the local debug key, so it
                          installs straight onto a device
build.cmd --release       release APK — smaller, but UNSIGNED; sign it
                          yourself before it will install
build.cmd --clean         wipe build outputs first
build.cmd --install       adb-install the result when the build succeeds
```

The script finds the toolchain (`tools/` first, then this machine's JDK and
SDK), checks the sources are all present, runs Gradle, then **verifies the
APK actually contains** its manifest, its dex and the viewer page — a Gradle
`BUILD SUCCESSFUL` on its own is not proof — and stages the result in
`dist/`.

### Signing a release build

`--release` produces an unsigned APK. To sign it:

```bash
tools/android-sdk/build-tools/35.0.0/apksigner sign \
    --ks my.jks --out streaming-server.apk \
    dist/streaming-server-1.4-release-unsigned.apk
```

Keystores are git-ignored (`*.jks`, `*.keystore`, `keystore.properties`) —
keep them out of the repository.

### Building in Android Studio instead

Open the project folder and build normally. Studio writes its own
`local.properties`. Its bundled JBR may be newer than JDK 23, which Gradle
8.11.1 will reject — if so, point *Settings → Build Tools → Gradle → Gradle
JDK* at a JDK 17, or at the one in `tools/jdk`.

---

## How it works

Three source files, about 1,100 lines including the viewer page.

| File | Role |
| --- | --- |
| [`StreamRelay.kt`](app/src/main/java/com/example/streamserver/StreamRelay.kt) | the whole server: port binding, protocol sniffing, publisher sessions, HTTP, WebSocket, fan-out |
| [`MainActivity.kt`](app/src/main/java/com/example/streamserver/MainActivity.kt) | the UI — a WebView onto the served page (API 21+) or a native player UI (API 19/20) |
| [`StreamPlayerView.kt`](app/src/main/java/com/example/streamserver/StreamPlayerView.kt) | `MediaCodec` decoder drawing onto a `SurfaceView`, for the API 19/20 path |
| [`assets/index.html`](app/src/main/assets/index.html) | the viewer page: WebSocket in, fMP4 remux in JavaScript, MSE out |

### One port, two protocols

`handleConnection` reads the first 7 bytes and pushes them back. A
connection starting with `STREAM` or `CHECK` is a publisher; anything else is
treated as HTTP. Frames are fanned out to *sinks* — a WebSocket viewer and
the device's own screen are the same kind of subscriber, one just skips the
socket.

A new sink waits for the next keyframe before it is fed anything, so a
mid-stream viewer never sees a broken picture.

### Wire protocol

**Publisher — raw TCP**

```
→  STREAM <key> [token]\n        ←  OK <token>\n  |  BUSY\n  |  BAD\n
→  CHECK <key>\n                 ←  FREE\n  |  BUSY\n  |  BAD\n
```

then, repeatedly:

| Field | Size | Meaning |
| --- | --- | --- |
| `payloadLen` | u32 big-endian | bytes of payload that follow the header |
| `flags` | u8 | bit 0 = keyframe, bit 1 = audio frame |
| `ptsMs` | u64 big-endian | presentation timestamp, milliseconds |
| `payload` | `payloadLen` | H.264 Annex-B (SPS/PPS prepended to keyframes), or AAC ADTS when bit 1 is set |

Maximum frame: 4 MB. A publisher that sends nothing for 60 s is dropped.

**Browser — HTTP on the same port**

| Request | Response |
| --- | --- |
| `GET /` | the viewer page |
| `GET /info` | `{"version","ips","viewerPort","streamPort","live"}` |
| `GET /ws?key=K` | WebSocket; each binary message is `u8 flags`, `u64be pts`, payload |

`viewerPort` and `streamPort` are the same number — they are kept as separate
fields for compatibility with pre-1.1 clients, which used two ports.

---

## Project layout

```
android-streaming-server/
├── app/src/main/
│   ├── java/com/example/streamserver/   MainActivity, StreamRelay, StreamPlayerView
│   ├── assets/index.html                the viewer page, served as-is
│   ├── res/                             icon, theme, strings
│   └── AndroidManifest.xml
├── build.cmd / build.sh                 build → dist/
├── download-tools.cmd / .sh             toolchain → tools/
├── gradlew / gradlew.bat                Gradle wrapper (8.11.1)
├── tools/                               downloaded toolchain   (git-ignored)
└── dist/                                built APK              (git-ignored)
```

`local.properties` is machine-local and git-ignored; the scripts rewrite it
on every run, so a moved checkout keeps working.

---

## Troubleshooting

**The viewer page loads but nothing plays.** Nothing is publishing to that
key yet, or the publisher has not sent a keyframe. The status line says
`WAITING FOR STREAM` until a keyframe arrives.

**A browser on the LAN cannot reach the page.** Both devices must be on the
same network, and some Wi-Fi access points isolate clients from each other
("AP isolation"). Mobile-data connections will not work — the device needs a
LAN address, which the app lists on screen.

**The publisher gets `BUSY`.** Another publisher holds that key. Wait for it
to drop, or pick a different key.

**The port changed between runs.** Something else had taken the preferred
one. The app always shows the current port; the viewer page picks it up from
`/info` automatically.

**Gradle refuses to start / "Unsupported class file major version".** The JDK
is outside 17–23. Run `download-tools` to get a private JDK 17 in `tools/`,
which the build scripts prefer over the system one.

**No audio in the browser.** The video element starts muted by browser
policy — unmute it in the player controls. The native API 19/20 player is
video-only.

---

## Contributing

The repository is public: anyone may clone it, and anyone may propose a
change. `main` is protected — it takes pull requests only, and a pull request
needs an approving review from the repository owner before it can be merged.

```bash
# 1. fork on GitHub, then
git clone https://github.com/<you>/android-streaming-server.git
cd android-streaming-server
git checkout -b my-change

# 2. make it build before you send it
./download-tools.sh && ./build.sh        # build.cmd on Windows

# 3. push to YOUR fork and open a pull request against ErickDoppler/main
git push origin my-change
```

You push branches to your own fork, not to this repository — that is how
GitHub works for anyone who is not a collaborator here, and it needs no
permission from anyone. If you are added as a collaborator you can push
branches here directly, but `main` still only moves through a reviewed pull
request.

---

## Related projects

- **`node-streaming-server`** — the same relay as a Node.js server; identical
  wire protocol and viewer page.
- **`android-stream-publisher`** — an Android publisher that encodes the
  camera and pushes it to either server.

---

## Licence

No licence file is present yet, so default copyright applies: the code is
readable here, but not yet granted for reuse. Add a `LICENSE` file to change
that.
