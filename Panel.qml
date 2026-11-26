// Solar Scope bar-widget entry point. Structure mirrors Omarchy's
// shell/plugins/panels/elsewhen/Panel.qml (qs.Ui Panel root + bar button +
// KeyboardPanel + IpcHandler). Colours: bar.foreground -> Commons.Color.foreground,
// which Omarchy loads from the current theme (~/.local/state/omarchy/current/theme/colors.toml).
// UNTESTED against a live Omarchy shell (not available on the build box).
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import Quickshell.Io
import "." as Local
import "Orbits.js" as Orbits
import "OrbitsAdapter.js" as Adapter
import "Extras.js" as Extras

Panel {
    id: root
    moduleName: "solarscope"
    ipcTarget: "solarscope"
    manageIpc: false

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // Omarchy 4.0.6 Bar.qml: the slot MouseArea (modulePointer) takes left presses and calls
    // triggerPress(button) on the slot item (moduleClickTargetAt fallback). Same contract as WidgetButton.
    function triggerPress(b) { if (b === Qt.LeftButton) root.toggle() }

    readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property bool showPluto: setting("showPluto", false) === true
    readonly property bool showNames: setting("showNames", true) !== false
    readonly property bool showRoadster: setting("showRoadster", false) === true

    // Live data: Orbits.js (no Python at runtime). Recomputed on open/data reload/manual refresh, then only when
    // a body could have moved >= ~0.5 px at the current zoom/size (scope.moveIntervalMs), capped at once a minute.
    property var bodies: []
    property var _orbitCache: ({})
    property real _lastCompute: 0
    property int orbitsCalls: 0      // QA counters (read by the harness)
    property int clockFires: 0
    function refresh() {
        root.orbitsCalls++
        root._lastCompute = Date.now()
        var jdNow = Orbits.toJdTdb(new Date())
        root.liveBodies = Adapter.build(Orbits, jdNow, root._orbitCache, {})
        root.extraRows = Extras.build(root._extrasEph, root.catalog, jdNow, root.liveBodies)   // table only (pages 2/3, Roadster row)
        if (root.playing) {}   // the next play tick draws; an extra out-of-cadence frame here made a short step (judder)
        else if (root.offsetActive) root._playFrame(); else root.bodies = root.liveBodies
        root._schedule()
    }

    // ---- Playback (Scope Director ruling, updated): ambient motion the whole time the panel is open,
    // forward only, starting at 3 d/s. Draw time = now + playOffset; it wraps back to live (fade) after one
    // Neptune sidereal orbit. Table and card always show LIVE values (liveBodies); the header shows the offset.
    // '.' pauses on live, 0 returns to live (Space: names on/off). Closed: no timers, no frames.
    property var liveBodies: []
    // Default 3 d/s.
    readonly property var playSpeeds: [1, 3, 5, 30, 100]   // days per second
    property int speedIdx: 1
    readonly property real playSpeed: playSpeeds[speedIdx]
    // Loop length: one Neptune sidereal orbit from Ephemeris's data (Orbits.js bodies): stats.period_days, else the
    // mean motion of its elements (L rate, deg/century), else Kepler's 3rd law from a; no Neptune: one year.
    function _neptuneLoop() {
        var b = null; try { b = Orbits.bodies().filter(function(x){ return x && x.id === "neptune" })[0] } catch (e) {}
        var el = b && b.elements
        if (b && b.stats && b.stats.period_days > 0) return { days: b.stats.period_days, src: "Orbits.js neptune stats.period_days" }
        if (el && el.L && el.L[1] > 0) return { days: 36525 * 360 / el.L[1], src: "Orbits.js neptune elements L rate (mean motion)" }
        if (el && el.a && el.a[0] > 0) return { days: 365.25 * Math.pow(el.a[0], 1.5), src: "Orbits.js neptune elements a (Kepler)" }
        return { days: 365.25, src: "fallback: no Neptune data, one year" }
    }
    readonly property var loopInfo: _neptuneLoop()   // computed once (no reactive inputs)
    readonly property real loopMs: loopInfo.days * 86400000
    property bool playing: false
    property real playOffset: 0      // ms ahead of real time
    property int playTicks: 0        // QA counter: Ephemeris snapshots built for playback (keyframes)
    readonly property bool offsetActive: playing || playOffset !== 0
    function play(on) { root.playing = on && root.opened }
    function togglePlay() { if (root.playing) root.returnToLive(); else root.play(true) }   // '.': pause on live
    function stepSpeed(d) { root.speedIdx = Math.max(0, Math.min(root.playSpeeds.length - 1, root.speedIdx + d)) }
    function returnToLive() { root.play(false); root.wrapFade = false; root.playOffset = 0; root.bodies = root.liveBodies }
    property bool wrapFade: false    // loop wrap: scene fades out (~300 ms), offset jumps to 0, scene fades back in
    property real _wrapAt: 0
    // Motion: one FrameAnimation tick per rendered frame (vsync-paced), not a coarse Timer. Each frame advances the sim
    // time by the real frame time x speed. Positions come from Ephemeris (Orbits.js via Adapter.build) only at keyframes,
    // computed AHEAD: segment A -> B spans keyMs of real time (speed x keyMs/1000 days); every frame between, the view
    // places each dot on its ring at u = playPhase with a cubic Hermite in longitude (keyframe longitudes + angular
    // rates from the Ephemeris velocities), so motion is exact at keyframes and C1-smooth between them, at any speed.
    readonly property int keyMs: 250
    property real _keyA: 0              // absolute draw time (epoch ms) of keyframe A (segment start)
    property real _keyB: 0              // ... of keyframe B (segment end, computed ahead)
    property real playSegDays: 0        // B - A in days (view: Hermite tangent scale)
    property real playPhase: 1          // 0..1 position of the draw time inside A -> B (set every frame)
    property int playFrames: 0          // QA counter: FrameAnimation ticks
    // Motion cadence: positions update on every N-th frame, N = round(frame period / measured frame time), so updates
    // land on vsync at an even interval (60 Hz display: every 3rd frame = 20 Hz, every 2nd = 30 Hz; no 16/33 ms mix).
    // Sim time still advances by the real time since the last update x speed. Slow speeds move < 0.4 px per update,
    // so 20 Hz is enough there; fast speeds get 30 Hz.
    property real motionHz: 20   // motion updates/s, every 3rd frame at 60 Hz (30 = every 2nd: smoother at 100 d/s, ~+0.5% PC CPU)
    property real _frameMs: 16.667      // smoothed frame time (ms)
    property real _acc: 0               // real ms since the last motion update
    property int _skip: 0               // frames since the last motion update
    property int playUpdates: 0         // QA counter: motion updates
    function _build(t) { root.playTicks++; return Adapter.build(Orbits, Orbits.toJdTdb(new Date(t)), root._orbitCache, { trailEverySec: 1e12 }) }
    function _playFrame() { root.bodies = root._build(Date.now() + root.playOffset) }   // paused with an offset (QA): one snapshot
    function _segLen() { return Math.max(60000, root.playSpeed * 86400 * root.keyMs) }   // sim ms per keyframe segment
    function _startSeg() {   // (re)start at the current draw time: A = now (snap), B one segment ahead
        var t = Date.now() + root.playOffset
        root._keyA = t; root.playPhase = 0; root.playSegDays = 0
        root.bodies = root._build(t)
        root._nextKey(t + root._segLen())
    }
    function _nextKey(tB) { root._keyB = tB; root.playSegDays = (tB - root._keyA) / 86400000; root.bodies = root._build(tB) }
    onPlayingChanged: { root._keyA = 0; root._keyB = 0; root._acc = 0; root._skip = 1000 }   // _skip: first frame updates   // the first frame after a start (re)starts the segment at the draw time
    FrameAnimation {
        id: playAnim
        running: root.opened && root.playing   // closed or stopped: not running (no ticks, no frames)
        onTriggered: {
            root.playFrames++
            var dt = Math.max(0, Math.min(100, frameTime * 1000))   // real ms since the previous frame, clamped after stalls
            if (dt > 0) root._frameMs += (Math.min(dt, 50) - root._frameMs) * 0.05
            if (root.wrapFade) {   // faded out: jump back to live time, then fade in
                if (Date.now() - root._wrapAt < 300) return
                root.playOffset = 0; root.wrapFade = false; root._startSeg(); return
            }
            root._acc += dt
            if (++root._skip < Math.max(1, Math.round(1000 / root.motionHz / root._frameMs))) return   // not this frame
            root._skip = 0; root.playUpdates++
            var next = root.playOffset + root.playSpeed * 86400 * root._acc
            root._acc = 0
            if (next >= root.loopMs) { root.wrapFade = true; root._wrapAt = Date.now(); return }
            root.playOffset = next
            var t = Date.now() + next
            if (t < root._keyA || t >= root._keyB + root._segLen()) { root._startSeg(); return }   // offset set from outside, or a long stall
            if (t >= root._keyB) { root._keyA = root._keyB; root._nextKey(root._keyB + root._segLen()) }
            root.playPhase = Math.max(0, Math.min(1, (t - root._keyA) / (root._keyB - root._keyA)))
        }
    }
    readonly property string playText: {
        if (!offsetActive) return ""
        var d = playOffset / 86400000, t = Math.floor(d) <= 365 ? Math.floor(d) + "d" : (d / 365.25).toFixed(1) + "y"
        return (playing ? "\u25b6 " : "\u2016 ") + playSpeed + " d/s \u00b7 T+" + t
    }
    // One single-shot clock while open, nothing while closed. Next wake = earliest of: wall-clock minute
    // (date text HH:MM), the next 'updated Xm ago' rollover (fetchedAt + 30 s + k*60 s), positions due.
    function _posIntervalMs() {
        var s = panelContent.scope, m = s && typeof s.moveIntervalMs === "number" ? s.moveIntervalMs : 60000
        return Math.max(1000, Math.min(60000, m))
    }
    function _schedule() {
        if (!root.opened) { clock.stop(); return }   // live clock keeps table/card values current during playback too
        var t = Date.now(), next = Math.floor(t / 60000) * 60000 + 60000
        var u = (typeof root.ephFetchedAt === "number" && isFinite(root.ephFetchedAt)) ? root.ephFetchedAt : root.lastUpdated
        if (typeof u === "number" && isFinite(u)) { var r = u + 30000 + Math.ceil((t - u - 30000 + 1) / 60000) * 60000; if (r > t) next = Math.min(next, r) }
        next = Math.min(next, root._lastCompute + root._posIntervalMs())
        clock.interval = Math.max(250, next - t + 20)
        clock.restart()
    }
    Timer {
        id: clock
        repeat: false
        onTriggered: {
            root.clockFires++
            root.now = Date.now()
            if (root.now - root._lastCompute >= root._posIntervalMs() - 50) root.refresh()
            else root._schedule()
        }
    }
    onEphFetchedAtChanged: _schedule()
    Component.onCompleted: { _shownHolo = holo; if (opened) { refresh(); play(true) } }
    Connections { target: panelContent.scope; ignoreUnknownSignals: true; function onMoveIntervalMsChanged() { root._schedule() } }
    onLastUpdatedChanged: _schedule()

    // ---- Ephemeris cache (INTERFACE.md section d) ----
    // Loaded at shell start (this file is the bar-widget entry point), never on panel open.
    // Until a file loads, Orbits.js uses the orbital-elements fallback, so it works offline.
    readonly property string ephemCacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/solar-scope/ephemeris"
    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
    property var _fetched: ({})          // id -> fetched_utc ms
    property string refreshStatus: ""    // last OK/ERROR line (subtle status only; never blocks)
    Instantiator {
        id: bodyFiles
        model: Orbits.bodyIds().filter(function (id) { return id !== "sun" })
        delegate: FileView {
            path: root.ephemCacheDir + "/" + modelData + ".json"
            blockLoading: false
            watchChanges: true
            onFileChanged: reload()
            onLoaded: {
                var d = null
                try { d = JSON.parse(text()) } catch (e) { d = null }
                if (d) { Orbits.setCache(modelData, d); root._fetched[modelData] = Date.parse(d.fetched_utc) || 0 }
                root._touchUpdated()
                root._orbitCache = ({})
                if (root.opened) Qt.callLater(root.refresh)
            }
        }
    }
    // live.json (written by update_cache.py --live) -> Orbits.setLiveText. Guarded: older Orbits.js lacks it.
    FileView {
        id: liveFile
        path: root.ephemCacheDir + "/live.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (typeof Orbits.setLiveText !== "function") return
            try { Orbits.setLiveText(text()) } catch (e) { console.warn("solarscope: live.json rejected:", e) }
            root._orbitCache = ({})
            root._touchUpdated()
            if (root.opened) Qt.callLater(root.refresh)
        }
    }
    // status.json (INTERFACE.md): {status ok|error, fetchedAt ISO|null, lastError}. Unknown fields ignored.
    property string ephStatus: ""
    property var ephFetchedAt: null
    property string ephError: ""
    property var ephStaleBodies: []      // status.json staleBodies: ids that kept cached values
    FileView {
        id: statusFile
        path: root.ephemCacheDir + "/status.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var d = null
            try { d = JSON.parse(text()) } catch (e) { d = null }
            if (!d) return
            root.ephStatus = d.status === "error" ? "error" : (d.status === "ok" ? "ok" : "")
            var f = Date.parse(d.fetchedAt || d.last_success_utc || "")
            root.ephFetchedAt = isFinite(f) ? f : null
            root.ephError = String(d.lastError || d.last_error || "")
            root.ephStaleBodies = Array.isArray(d.staleBodies) ? d.staleBodies : []
        }
    }
    // ---- v1.1 table-only bodies (pages 2/3 and the Roadster row). Own catalog + own Orbits.create() ephemeris:
    // nothing here reaches `bodies`/`liveBodies`, so the scope never sees these bodies.
    property var catalog: []             // catalog.json bodies (bundled)
    property var _extrasEph: null        // Orbits.create(catalog), fed by extras.json
    property string _extrasText: ""
    property var extrasFetchedAt: null   // extras.json fetched_utc (epoch ms) | null
    property real _extrasJdStop: 0       // extras.json last row JD (window end)
    property int extrasIncomplete: 0     // catalog bodies without rows in extras.json, or listed stale (a partial download)
    property real _extrasTriedAt: 0      // epoch ms of the last automatic --extras run (this session)
    property var extraRows: []           // Extras.build output, recomputed in refresh()
    function _applyExtras() {
        if (!root.catalog.length) return
        if (!root._extrasEph) root._extrasEph = Orbits.create({ bodies: root.catalog }, { allowFallback: false })
        var d = null
        try { d = root._extrasText ? JSON.parse(root._extrasText) : null } catch (e) { d = null }
        root._extrasEph.setLive(d && d.bodies ? d : null)
        var f = d ? Date.parse(d.fetched_utc || d.fetchedAt || "") : NaN
        root.extrasFetchedAt = isFinite(f) ? f : null
        var stop = 0
        if (d && d.bodies) for (var id in d.bodies) { var r = d.bodies[id] && d.bodies[id].rows; if (r && r.length) stop = Math.max(stop, r[r.length - 1][0]) }
        root._extrasJdStop = stop
        var stale = d && Array.isArray(d.staleBodies) ? d.staleBodies : [], inc = 0
        if (d && d.bodies) for (var k = 0; k < root.catalog.length; k++) { var c = root.catalog[k].id, b = d.bodies[c]
            if (!b || !b.rows || !b.rows.length || stale.indexOf(c) >= 0) inc++ }
        root.extrasIncomplete = inc
        if (root.opened) Qt.callLater(root.refresh)
    }
    FileView {
        id: catalogFile
        path: root.pluginDir + "/catalog.json"
        blockLoading: false
        printErrors: false
        onLoaded: {
            var d = null
            try { d = JSON.parse(text()) } catch (e) { d = null }
            root.catalog = d && Array.isArray(d.bodies) ? d.bodies.filter(function (b) { return b && b.id && b.horizons_id }) : []
            root._extrasEph = null
            root._applyExtras()
        }
    }
    FileView {
        id: extrasFile
        path: root.ephemCacheDir + "/extras.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root._extrasText = text(); root._applyExtras() }
    }
    // Extras are due when missing, older than 7 days, within 60 days of their window end, or incomplete
    // (a partial download: update_cache.py then fetches just the missing bodies). Automatic runs are chained
    // on planet runs (every 30 min) and at most one per 25 min, so a JPL outage is not retried on every manual refresh.
    function extrasDue() {
        if (!root.catalog.length) return ""
        if (root._extrasTriedAt > 0 && Date.now() - root._extrasTriedAt < 25 * 60000) return ""
        if (root.extrasFetchedAt === null) return "missing"
        if (Date.now() - root.extrasFetchedAt > 7 * 86400000) return "older than 7 days"
        if (root._extrasJdStop - Orbits.toJdTdb(new Date()) < 60) return "within 60 days of window end"
        if (root.extrasIncomplete > 0) return "incomplete: " + root.extrasIncomplete + " bodies"
        return ""
    }
    // Chained after a successful planet run (never instead of one), so planet live data is never delayed.
    Timer {
        id: extrasChain
        interval: 2000; repeat: false
        property int tries: 0
        onTriggered: {
            var why = root.extrasDue(); if (why === "") return
            if (refreshProc.running) { if (++tries < 30) restart(); return }
            tries = 0
            if (root.runUpdate(["--extras"], "extras: " + why)) root._extrasTriedAt = Date.now()
        }
    }

    // A FileView watcher misses files that did not exist at startup (first run), so reload
    // everything explicitly once update_cache.py reports OK.
    function reloadCache() {
        for (var i = 0; i < bodyFiles.count; i++) { var f = bodyFiles.objectAt(i); if (f) f.reload() }
        liveFile.reload(); statusFile.reload(); extrasFile.reload()
    }
    // Orbits.lastUpdated() (epoch ms | null): header fallback after status.json fetchedAt (G18, SolarScopePanel).
    property var lastUpdated: null
    function _touchUpdated() {
        var t = typeof Orbits.lastUpdated === "function" ? Orbits.lastUpdated() : null
        root.lastUpdated = (typeof t === "number" && isFinite(t)) ? t : null
    }
    // Label clock: advanced only by `clock` above (minute-aligned), paused while closed.
    property real now: Date.now()
    onOpenedChanged: if (opened) { root._shownHolo = root.holo; root.now = Date.now(); root._touchUpdated(); root.playOffset = 0; root.refresh(); root.play(true) }
                    else { root.play(false); root.wrapFade = false; root.playOffset = 0; clock.stop() }

    // Holo mode, persisted across restarts in <cache>/solar-scope/ui.json via an atomic FileView
    // (pattern from asteroid-radar Panel.qml:352-363). PersistentProperties only survive reloads.
    property bool holo: false
    property bool _shownHolo: false   // the view's mode: follows holo while open; a change while closed (IPC) shows on open, so closed stays paint-free
    onHoloChanged: if (opened) _shownHolo = holo
    readonly property color accent: Commons.Color.accent || "#7fd4d4"
    FileView {
        id: uiFile
        path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/solar-scope/ui.json"
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try { var d = JSON.parse(text()); if (typeof d.holo === "boolean") root.holo = d.holo } catch (e) {}
        }
    }
    function setHolo(on) {
        if (on === root.holo) return
        root.holo = on
        uiFile.setText(JSON.stringify({ holo: on }) + "\n")
    }

    // Weekly full refresh gate: missing, older than 7 days, or within 90 days of the cache edge.
    function cacheStale() {
        var now = Date.now(), jdNow = Orbits.toJdTdb(new Date())
        var ids = Orbits.bodyIds().filter(function (id) { return id !== "sun" })
        for (var i = 0; i < ids.length; i++) {
            var cov = Orbits.cacheCoverage(ids[i]), f = root._fetched[ids[i]]
            if (!cov || !f) return "missing " + ids[i]
            if (now - f > 7 * 86400000) return "older than 7 days"
            if (cov[1] - jdNow < 90) return "within 90 days of cache edge"
        }
        return ""
    }
    // One background Process for every mode, so runs never overlap (also keeps JPL load low).
    function runUpdate(extraArgs, why) {
        if (refreshProc.running) { console.log("solarscope: refresh already running, skipped (" + why + ")"); return false }
        refreshProc.command = ["python3", "update_cache.py"].concat(extraArgs).concat(["--cache-dir", root.ephemCacheDir])
        console.log("solarscope: ephemeris refresh (" + why + "): " + extraArgs.join(" "))
        refreshProc.running = true
        return true
    }
    // Scheduled: full refresh when stale, otherwise live (update_cache.py skips live if < 25 min old).
    function scheduledRefresh() {
        var stale = root.cacheStale()
        if (stale !== "") root.runUpdate([], "full: " + stale)
        else root.runUpdate(["--live"], "scheduled")
    }
    // Manual ('r' in the panel, or IPC refresh): live now, bypassing the 25-min skip.
    // Debounced: manual triggers within 60 s of the last accepted one are ignored (r and IPC alike).
    property real _lastManual: 0
    readonly property real manualRefreshAt: _lastManual   // read-only, for the 'refresh in Ns' hint
    function manualRefresh() {
        var t = Date.now()
        if (t - root._lastManual < 60000) { console.log("solarscope: manual refresh ignored (within 60 s of the last one)"); return false }
        if (!root.runUpdate(["--live", "--force"], "manual")) return false
        root._lastManual = t
        return true
    }
    Timer {  // first run ~10 s after shell start (FileViews have loaded), then every 30 min
        id: refreshTimer
        interval: 10000; running: true; repeat: true
        onTriggered: { interval = 30 * 60 * 1000; root.scheduledRefresh() }
    }
    Process {  // background; never blocks render. update_cache.py prints one OK/ERROR line.
        id: refreshProc
        running: false
        workingDirectory: root.pluginDir
        stdout: StdioCollector {
            onStreamFinished: {
                var line = text.trim().split("\n").pop()
                root.refreshStatus = line
                if (line.indexOf("OK ") === 0) {   // FileView watchChanges reloads files
                    console.log("solarscope ephemeris:", line); root.reloadCache()
                    if (line.indexOf("OK extras") !== 0 && root.extrasDue() !== "") { extrasChain.tries = 0; extrasChain.restart() }
                }
                else console.warn("solarscope ephemeris refresh failed:", line || "(no output)", "- using cached/elements data")
            }
        }
    }

    IpcHandler {
        target: root.ipcTarget
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.toggle() }
        function select(id: string): string { panelContent.scope.select(id); return id }
        function refresh(): string { root.refresh(); return root.bodies.length + " bodies; " + (root.manualRefresh() ? "ephemeris refresh started" : "ephemeris refresh skipped (running or within 60 s)") }
        // No-key control (QA request R1). Text in, text out; each works open or closed (closed: no frames start).
        function setSpeed(dps: string): string {   // snaps to the nearest of playSpeeds; returns the speed applied
            var v = parseFloat(dps), best = root.speedIdx
            if (isFinite(v)) { best = 0; for (var i = 1; i < root.playSpeeds.length; i++) if (Math.abs(root.playSpeeds[i] - v) < Math.abs(root.playSpeeds[best] - v)) best = i }
            root.speedIdx = best
            return String(root.playSpeed)
        }
        function setPlaying(on: string): string {   // false: pause on live ('.'); closed: already stopped on live (open always resumes)
            if (root._ipcOn(on)) root.play(true); else if (root.opened) root.returnToLive()
            return String(root.playing)
        }
        function setHolo(on: string): string { root.setHolo(root._ipcOn(on)); return root.holo ? "holo" : "plain" }   // persists ui.json
        function setNames(on: string): string { panelContent.scope.showNames = root._ipcOn(on); return String(panelContent.scope.showNames) }   // as Space / n
        function state(): string {
            return JSON.stringify({ opened: root.opened, holo: root.holo, speed: root.playSpeed, speedIdx: root.speedIdx,
                                    playing: root.playing, playUpdates: root.playUpdates, showNames: panelContent.scope.showNames,
                                    page: body.page, showRoadster: body.showRoadster,
                                    extrasFetchedAt: root.extrasFetchedAt ? new Date(root.extrasFetchedAt).toISOString() : null,
                                    extrasIncomplete: root.extrasIncomplete })
        }
        // v1.1 pages (table only; the scope is never touched)
        function setPage(n: string): string { body.setPage(parseInt(n)); return String(body.page) }   // as 1 / 2 / 3
        function setRoadster(on: string): string { body.showRoadster = root._ipcOn(on); return String(body.showRoadster) }   // as t (persists)
        function table(): string { return body.tableJson() }   // rows of the shown page; null where the table shows an en dash
    }
    function _ipcOn(s) { return ["true", "1", "on", "yes"].indexOf(String(s).trim().toLowerCase()) >= 0 }

    Item {
        id: button
        anchors.fill: parent
        implicitWidth: Style.bar.statusSlot
        implicitHeight: Style.bar.statusSlot
        Local.BarWidget {   // ./BarWidget.qml (qualified to avoid clashing with qs.Ui.BarWidget)
            anchors.centerIn: parent
            foreground: root.foreground
            size: 14
            onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
        }
    }

    KeyboardPanel {
        id: panel
        WlrLayershell.namespace: "io.github.advocu.solar-scope"
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: panelContent.scope
        contentWidth: panel.fittedContentWidth(Style.space(600))
        contentHeight: panel.fittedContentHeight(Style.space(560), Style.space(760))

        Item {
            id: panelContent
            property alias scope: body.scope
            anchors.fill: parent
            Local.SolarScopePanel {
                id: body
                anchors.fill: parent
                bodies: root.bodies
                fg: root.foreground
                accent: root.accent
                background: Commons.Color.background
                fontFamily: root.fontFamily
                showPluto: root.showPluto
                holo: root._shownHolo
                lastUpdated: root.lastUpdated
                now: root.now
                statusText: root.refreshStatus
                ephStatus: root.ephStatus
                ephFetchedAt: root.ephFetchedAt
                ephError: root.ephError
                staleBodies: root.ephStaleBodies
                onShowPlutoChanged: if (showPluto !== root.showPluto) root.persistSettings({ showPluto: showPluto })
                showRoadster: root.showRoadster
                onShowRoadsterChanged: if (showRoadster !== root.showRoadster) root.persistSettings({ showRoadster: showRoadster })
                extraRows: root.extraRows
                onHoloToggleRequested: root.setHolo(!root.holo)
                onRefreshRequested: { root.manualRefresh(); root.refresh() }
                lastManualRefresh: root.manualRefreshAt
                showNames: root.showNames
                onCloseRequested: root.close()
                playText: root.playText
                liveBodies: root.liveBodies
                playbackOffsetMs: root.playOffset
                offsetActive: root.offsetActive
                wrapFade: root.wrapFade
                playing: root.playing
                playPhase: root.playPhase
                playSegDays: root.playSegDays
                active: root.opened
                onPlayToggleRequested: root.togglePlay()
                onSpeedStepRequested: (d) => root.stepSpeed(d)
                onLiveRequested: root.returnToLive()
                                onSourceLinkRequested: (url) => Quickshell.execDetached(["omarchy-launch-browser", url])
            }
        }
    }
}
