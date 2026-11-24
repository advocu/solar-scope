// Solar Scope view: one Canvas, one hue (fg in plain mode, accent in holo), repaint-on-demand.
// Camera/projection (computeFrame) and hologram glow constants ported from Asteroid Radar (Panel.qml): Copyright (c) 2026 chanwook lee, MIT License. See THIRD_PARTY.md.
import QtQuick
import QtQuick.Effects

Item {
    id: root
    // ---- in ----
    property var bodies: []
    property color fg: "#cacccc"   // Commons.Color.foreground default
    property color bg: "transparent"
    property color dim: Qt.darker(fg, 1.55)  // same derivation as Elsewhen
    property string fontFamily: "monospace"  // bind to bar.fontFamily (Omarchy font)
    property real azimuth: -34.3775   // AR yaw -0.6 rad; deg (view azimuth on screen)
    property real tilt: 60.1606      // AR pitch 1.05 rad; deg, 0 = edge-on, 90 = top-down
    property bool flatView: true     // default (Suyash): top-down (AR pitch 0), rings are true circles; false = AR tilt (QA flag)
    readonly property real _tiltEff: flatView ? 90 : tilt
    onFlatViewChanged: { _slotEpoch++; invalidate() }
    // Ring spacing: 0 = pure log map; 1 = near-uniform ring gaps (each visible orbit an equal radial step out to the
    // panel edge; dots stay at true longitude on their ring). Between knots: log interpolation, so it stays monotone.
    property real ringSpread: 1
    property var _ringTab: []        // [[AU, unit radius]] knots, sorted
    property real maxAU: 40        // outer edge of log scale
    property real r0: 0.3
    property real perspective: 0.25   // turntable depth cue (as Asteroid Radar); 0 = orthographic
    property bool showPluto: false // P: reveals bodies with default_visible:false (Pluto, other dwarfs)
    property bool showNames: true  // Space / n: planet names + leader lines on/off (visibility only; slots never re-deal)
    signal holoToggleRequested()
    property bool holo: false      // g: holo mode = everything in `accent`, softer lines
    property color accent: "#7fd4d4"   // bind Commons.Color.accent; fallback cyan-ish
    readonly property color ink: holo ? accent : fg
    readonly property color holoGlow: "#3fd8ff"   // AR holoGlow
    // MultiEffect needs a GPU scene graph; on the software renderer (offscreen QA) it draws nothing, so the canvas halo
    // stands in there. GPU (the real bar): AR's glow.
    readonly property bool glowFx: holo && GraphicsInfo.api !== GraphicsInfo.Software
    // QA/diagnostics: which holo glow path this backend uses (logged once at startup)
    readonly property string qaBackend: { var a = GraphicsInfo.api, G = GraphicsInfo; return a === G.Software ? "software" : a === G.OpenGL ? "rhi/opengl" : a === G.Vulkan ? "rhi/vulkan" : a === G.Direct3D11 ? "rhi/d3d11" : a === G.Direct3D12 ? "rhi/d3d12" : a === G.Metal ? "rhi/metal" : a === G.Unknown ? "unknown" : "api" + a }
    readonly property string qaGlowPath: GraphicsInfo.api === GraphicsInfo.Software ? "halo" : "multieffect"
    property bool _glowLogged: false
    function _logGlow() { if (_glowLogged || GraphicsInfo.api === GraphicsInfo.Unknown) return; _glowLogged = true; console.info("solar-scope: glow=" + qaGlowPath + " backend=" + qaBackend) }
    onQaBackendChanged: _logGlow()
    signal closeRequested()   // Esc with nothing selected
    property color cardBase: "transparent"   // card backing (opaque mask over the turning orbit layer); Panel passes the theme background
    property string dateText: ""   // bottom-left, e.g. "Sat 10/24 16:44"
    property bool showCard: true   // bottom-right info card for the selected body
    property bool showRings: false   // AU rings off: the orbit circles are the rings
    property string selectedId: ""
    // ---- out ----
    signal selectedChanged(string id)   // also via onSelectedIdChanged
    // Table rows for the panel: visible bodies except the Sun, with info(). Updated on data/toggle change.
    property var tableRows: []
    property bool offsetActive: false    // 0: back to live when offset, else reset view
    signal playToggleRequested(); signal speedStepRequested(int d); signal liveRequested()
    // Playback: `bodies` are drawn at now + offset; `liveBodies` (real time) feed the table, card and
    // detail line, so every number shown is a LIVE value. null = same as bodies.
    property var liveBodies: null
    property real playbackOffsetMs: 0    // draw time = now + this (0 = now); card/table values stay live
    property bool playing: false         // Panel.qml: playback frames running (labels use hysteresis only then)
    property bool wrapFade: false        // Panel.qml: true for ~300 ms while the playback loop wraps (scene fades out, then in)
    // Label stability during playback: see the label plan in _layout (fixed priority, re-planned ~1/s,
    // swept boxes, 15 s minimum hidden, <= 1 change in the last minute before a name may come back).
    property var _lab: ({})
    property int _labEpoch: 0       // bumps on every fresh placement; a name only slides within one epoch
    function _labReset() { _lab = ({}); _labEpoch++ }
    onPlayingChanged: { _labReset(); _prevPos = null }   // fresh placement whenever frames start or stop
    onWrapFadeChanged: if (!wrapFade) _labEpoch++   // loop wrap: the scene is hidden, names snap to new sides (shown state and change history kept)
    onFontFamilyChanged: _twCache = ({})
    property var heldLabels: []     // names kept at full opacity inside their 3 s window on a blocked spot (may touch a dot)
    readonly property int _labMinHiddenMs: 15000   // a hidden name stays hidden at least this long (churn <= 4/min per body)
    property var _labPos: ({})       // id -> [sx, sy, t, epoch] of the previous frame (dot velocity for the plan's sweep)
    property real _labPlanAt: -1e15  // time of the last label plan (re-run about once a second while playing)
    property int labelPlans: 0       // QA counter: label plans run
    property var _twCache: ({})
    function _tw(f, s) { var k = f + "|" + s, v = _twCache[k]; if (v === undefined) { v = _fm(f).advanceWidth(s); _twCache[k] = v } return v }
    // min time from appearing before a fade may start: 300 ms fade-in + 3 s at full opacity + one frame of slack
    readonly property int _labMinShownMs: 3400
    Item {   // QA handle for the canvas-drawn info card (geometry only, draws nothing)
        objectName: "card"
        visible: root.cardRect.length === 4
        x: visible ? root.cardRect[0] : 0; y: visible ? root.cardRect[1] : 0
        width: visible ? root.cardRect[2] : 0; height: visible ? root.cardRect[3] : 0
    }
    property var _live: []
    function _normLive() { if (!liveBodies) { _live = _bodies; return } var o = []; for (var i = 0; i < liveBodies.length; i++) { var n = _norm(liveBodies[i]); if (n) o.push(n) } _live = o }
    function _findLive(id) { for (var i = 0; i < _live.length; i++) if (_live[i].id === id) return _live[i]; return null }
    property int _liveRev: 0
    property var _stCache: null
    onLiveBodiesChanged: { _liveRev++; _normLive(); _updateRows() }   // no repaint: the next frame (or bodiesChanged) picks it up
    property var placedLabels: []
    property var placedMarkers: []  // dot + selected-ring boxes of the last paint (overlap check)
    property var cardRect: []       // [x, y, w, h] of the info card, [] when none (scanlines skip it)   // written by paint (nothing binds to it in the shell; read by the parity harness)
    function _updateRows() {
        var o = []
        for (var i = 0; i < _live.length; i++) { var b = _live[i]; if (b.type === "star" || !_visible(b)) continue; o.push({ id: b.id, name: b.name, info: info(b) }) }
        tableRows = o
    }
    function fmtLight(s) {
        if (!isFinite(s)) return "\u2013"
        if (s >= 3600) return Math.floor(s/3600) + "h " + Math.round((s % 3600)/60) + "m"
        return Math.floor(s/60) + "m " + (Math.round(s % 60) < 10 ? "0" : "") + Math.round(s % 60) + "s"
    }
    function fmtPeriod(d) { return !isFinite(d) ? "" : d >= 730 ? (d/365.25).toFixed(2) + " yr" : d.toFixed(1) + " d" }
    function resetView() { azimuth = -34.3775; tilt = 60.1606; maxAU = 40; _slotEpoch++; invalidate() }
    property bool active: true           // Panel.qml: panel open
    property int _slotEpoch: 0           // bumps on manual rotation/tilt: name slots re-deal then
    function _selProj() { for (var k = 0; k < _proj.length; k++) if (_proj[k].b.id === selectedId) return _proj[k]; return null }
    function _trailLines(s) {
        var L = []
        if (s && !offsetActive && s.b.trail && s.b.trail.length) {
            var pts = s.b.trail.map(function(q){ return _project(q[0], q[1], q[2]) }).concat([[s.sx, s.sy]])
            for (var j = 1; j < pts.length; j++) L.push([pts[j-1][0], pts[j-1][1], pts[j][0], pts[j][1], 0.9 * j / (pts.length - 1), 2])
        }
        return L
    }
    // Earth: the one exception to one-hue-per-mode (dot, ring, name, table row), both modes. QA: qaAccentItems().
    property color earthInk: "#ffb347"
    function qaAccentItems() {   // [{kind, x, y, w, h}] in view pixels: Earth's dot (with its ring) and name
        var r = []
        for (var i = 0; i < dotRep.count; i++) { var it = dotRep.itemAt(i); if (it && it.d.id === "earth") { var g = it.d.r + 2.5 + 1; r.push({ kind: "dot", x: it.x + it.d.r - g, y: it.y + it.d.r - g, w: 2 * g, h: 2 * g }) } }
        for (var j = 0; j < textRep.count; j++) { var tx = textRep.itemAt(j); if (tx && tx.t.e) r.push({ kind: "name", x: tx.x - 1, y: tx.y - 1, w: tx.width + 2, h: tx.height + 2 }) }
        return r
    }

    focus: true
    implicitWidth: 480; implicitHeight: 480
    readonly property real radiusPx: Math.min(width, height) / 2 - 12
    property var _proj: []     // [{b, sx, sy, info}]
    property var _orbits: []
    property string _orbitsKey: ""
    property string _geomKey: ""   // view geometry without azimuth (auto-rotation keeps slots and static caches)
    property var _cardCache: null   // [{pts:[[sx,sy]...]}]
    property bool _dirtyGeom: true

    // Normalise one Ephemeris snapshot entry (INTERFACE.md) -> internal {id,name,type,x..vz,orbit,trail,dv}.
    // Returns null (hidden) for entries with error, no position, or anything that throws.
    function _norm(e) {
        try {
            if (!e || e.error) return null
            var p = e.pos || (e.x !== undefined ? [e.x, e.y, e.z] : null)
            if (!p || p.length < 3 || !isFinite(p[0])) return null
            var v = e.vel || [e.vx || 0, e.vy || 0, e.vz || 0]
            return { id: e.id, name: e.name || e.id, type: e.type || e.kind || "asteroid", parent: e.parent,
                     x: p[0], y: p[1], z: p[2], vx: v[0], vy: v[1], vz: v[2], phase: e.phase,
                     orbit: e.orbit, trail: e.trail, dv: e.default_visible !== false, src: e }
        } catch (err) { return null }
    }
    property var _bodies: []
    function _normAll() { var o = []; for (var i = 0; i < (bodies || []).length; i++) { var n = _norm(bodies[i]); if (n) o.push(n) } _bodies = o }
    function _visible(b) { return b.dv || showPluto }
    function _scaleLog(r) { return Math.log10(1 + r / r0) / Math.log10(1 + maxAU / r0) }
    function _scale(r) {
        var u = _scaleLog(r), T = _ringTab; if (!(ringSpread > 0) || T.length < 2 || !(r > 0)) return radiusPx * u
        var z = Math.log10(1 + 40 / r0) / Math.log10(1 + maxAU / r0), v   // zoom (maxAU) still scales the map
        if (r <= T[0][0]) v = T[0][1] * r / T[0][0]
        else if (r >= T[T.length - 1][0]) v = T[T.length - 1][1] * Math.log10(1 + r / r0) / Math.log10(1 + T[T.length - 1][0] / r0)
        else for (var i = 1; i < T.length; i++) if (r <= T[i][0]) { var a = Math.log(T[i-1][0]), b = Math.log(T[i][0]); v = T[i-1][1] + (T[i][1] - T[i-1][1]) * (Math.log(r) - a) / (b - a); break }
        return radiusPx * (u + ringSpread * (v * z - u))
    }
    function _buildRingTab() {
        var A = []; for (var i = 0; i < _bodies.length; i++) { var b = _bodies[i]; if (_visible(b) && b.type !== "star") { var a = _orbitR(b); if (a > 0) A.push(a) } }
        A.sort(function(x, y){ return x - y }); var n = A.length, T = []
        for (var k = 0; k < n; k++) T.push([A[k], (k + 1) / n])
        _ringTab = T
    }
    function _project(x, y, z, az) {
        var r = Math.sqrt(x*x + y*y + z*z); if (r === 0) return [width/2, height/2]
        var k = _scale(r) / r
        var a = (az === undefined ? azimuth : az) * Math.PI/180, t = _tiltEff * Math.PI/180
        var xr = x*Math.cos(a) - y*Math.sin(a), yr = x*Math.sin(a) + y*Math.cos(a)
        var sy = yr*Math.sin(t) + z*Math.cos(t)
        var f = 1 / (1 + perspective * (yr*Math.cos(t) - z*Math.sin(t)) * k / radiusPx)   // far side shrinks, near side grows
        return [width/2 + xr*k*f, height/2 - sy*k*f]
    }
    function _elementsToPts(o) {
        var d = Math.PI/180, pts = [], n = 180
        var ci=Math.cos(o.i*d), si=Math.sin(o.i*d), cN=Math.cos(o.node*d), sN=Math.sin(o.node*d)
        var cw=Math.cos(o.peri*d), sw=Math.sin(o.peri*d)
        var maxE = o.e < 1 ? Math.PI : 0
        for (var j = 0; j <= n; j++) {
            var E = -maxE + 2*maxE*j/n
            var xp = o.a*(Math.cos(E)-o.e), yp = o.a*Math.sqrt(1-o.e*o.e)*Math.sin(E)
            var X = (cw*cN - sw*sN*ci)*xp + (-sw*cN - cw*sN*ci)*yp
            var Y = (cw*sN + sw*cN*ci)*xp + (-sw*sN + cw*cN*ci)*yp
            var Z = (sw*si)*xp + (cw*si)*yp
            pts.push([X, Y, Z])
        }
        return pts
    }
    function info(b) {
        var r = Math.sqrt(b.x*b.x + b.y*b.y + b.z*b.z)
        var v = Math.sqrt((b.vx||0)*(b.vx||0) + (b.vy||0)*(b.vy||0) + (b.vz||0)*(b.vz||0)) * 1731.456837
        var ph = b.phase !== undefined ? b.phase : ((Math.atan2(b.y, b.x)*180/Math.PI) + 360) % 360
        var e = b.src || {}
        // Prefer Ephemeris readout fields when present.
        if (isFinite(e.distance_km)) r = e.distance_km / 149597870.7
        if (isFinite(e.speed_km_s)) v = e.speed_km_s
        var lt = isFinite(e.light_time_s) ? e.light_time_s : r * 499.004784
        // Distance from Earth: from Earth's heliocentric position; NaN when Earth is absent.
        var earth = _findLive("earth"), de = NaN
        if (earth) { var dx = b.x - earth.x, dy = b.y - earth.y, dz = b.z - earth.z; de = Math.sqrt(dx*dx + dy*dy + dz*dz) }
        var st = e.stats || {}
        return { dist: r, distKm: isFinite(e.distance_km) ? e.distance_km : r * 149597870.7, distEarth: de,
                 speed: v, phase: ph, lightTime: lt,
                 radiusKm: isFinite(e.radius_km) ? e.radius_km : NaN, periodDays: isFinite(st.period_days) ? st.period_days : NaN }
    }
    function _group(n) {   // 1234567 -> "1,234,567"
        var s = String(Math.round(n)), o = ""
        while (s.length > 3) { o = "," + s.slice(-3) + o; s = s.slice(0, -3) }
        return s + o
    }
    function _km(n) { return n >= 1e9 ? (n/1e9).toFixed(3) + "B km" : n >= 1e6 ? (n/1e6).toFixed(2) + "M km" : _group(n) + " km" }
    // Readout lines for one body. Missing stats lines are skipped, never blank.
    function readout(b) {
        var i = info(b), L = [b.name]
        L.push("sun   " + i.dist.toFixed(3) + " AU")
        L.push("      " + _km(i.distKm))
        if (b.id !== "earth")   // no self-distance; en dash only when Earth is absent from the data
            L.push("earth " + (isFinite(i.distEarth) ? i.distEarth.toFixed(3) + " AU" : "\u2013"))
        L.push("speed " + i.speed.toFixed(2) + " km/s")
        L.push("light " + (i.lightTime >= 3600 ? (i.lightTime/3600).toFixed(2) + " h" : (i.lightTime/60).toFixed(1) + " min"))
        if (isFinite(i.radiusKm)) L.push("rad   " + (i.radiusKm >= 100 ? _group(i.radiusKm) : i.radiusKm.toPrecision(3)) + " km")
        if (isFinite(i.periodDays)) L.push("per   " + (i.periodDays >= 730 ? (i.periodDays/365.25).toFixed(2) + " yr" : i.periodDays.toFixed(1) + " d"))
        return L
    }
    // Orbits are drawn as circles in the ecliptic at each body's mean orbit radius (log scale); a dot sits on its
    // circle at its true heliocentric longitude. The real 3D position is kept for the table/card.
    property var _ringA: ({})
    function _orbitR(b) {
        if (_ringA[b.id] !== undefined) return _ringA[b.id]
        var src = b.orbit ? (Array.isArray(b.orbit) ? b.orbit : (b._orbitCache || (b._orbitCache = _elementsToPts(b.orbit)))) : null, a = 0
        if (src && src.length) { for (var i = 0; i < src.length; i++) a += Math.sqrt(src[i][0]*src[i][0] + src[i][1]*src[i][1] + src[i][2]*src[i][2]); a /= src.length }
        else a = Math.sqrt(b.x*b.x + b.y*b.y + b.z*b.z)
        _ringA[b.id] = a; return a
    }
    function _flat(b) { var a = _orbitR(b), l = Math.atan2(b.y, b.x); return a > 0 ? [a * Math.cos(l), a * Math.sin(l), 0] : [0, 0, 0] }
    function _rebuild() {
        var P = [], O = []; _buildRingTab()
        for (var i = 0; i < _bodies.length; i++) {
            var b = _bodies[i]; if (!_visible(b)) continue
            var fp = _flat(b), p = _project(fp[0], fp[1], fp[2])
            P.push({ b: b, sx: p[0], sy: p[1], f: fp })
            var a = _orbitR(b)
            if (a > 0 && b.type !== "star") { var C = []; for (var q = 0; q <= 96; q++) { var th = q / 96 * 2 * Math.PI; C.push([a * Math.cos(th), a * Math.sin(th), 0]) } O.push({ id: b.id, src: C }) }
        }
        // Orbit polylines are time-independent: reproject only when the view or the set of orbits changes
        // (playback frames move dots only).
        var key = [_tiltEff, ringSpread, maxAU, width, height].join() + "|" + O.map(function(o){ return o.id + ":" + o.src.length }).join()
        _geomKey = [_tiltEff, ringSpread, maxAU, width, height, _slotEpoch].join() + "|" + P.map(function(p){ return p.b.id }).join()
        if (key !== _orbitsKey) { _orbitsKey = key; _orbits = O.map(function(o){ return o.src.map(function(q){ return _project(q[0], q[1], q[2]) }) }) }
        _proj = P; _dirtyGeom = false
        if (!offsetActive) _updateMoveInterval()
    }
    // ms until the fastest visible body could move ~0.5 px at the current zoom/size (velocities are AU/day).
    property real moveIntervalMs: 60000
    function _updateMoveInterval() {
        var best = 0
        for (var i = 0; i < _bodies.length; i++) {
            var b = _bodies[i]; if (!_visible(b) || b.type === "star") continue
            var r = Math.sqrt(b.x*b.x + b.y*b.y + b.z*b.z); if (!(r > 0)) continue
            var v = Math.sqrt((b.vx||0)*(b.vx||0) + (b.vy||0)*(b.vy||0) + (b.vz||0)*(b.vz||0))
            var pxPerAU = Math.max(_scale(r) / r, (_scale(r * 1.001) - _scale(r)) / (r * 0.001))
            best = Math.max(best, pxPerAU * v / 86400000)
        }
        var ms = best > 0 ? 0.5 / best : 60000
        moveIntervalMs = Math.round(Math.max(1000, Math.min(60000, ms)) / 1000) * 1000
    }
    // Paint only when a dot moved >= 0.5 px since the last paint or the selected readout text changed.
    property var _paintedKey: null
    function _sameAsPainted() {
        var old = _paintedKey; if (!old) return false
        var P = [], sel = selectedId ? readoutFor(selectedId).join("|") : ""
        for (var i = 0; i < _bodies.length; i++) { var b = _bodies[i]; if (!_visible(b)) continue; var fp = _flat(b), p = _project(fp[0], fp[1], fp[2]); P.push([b.id, p[0], p[1]]) }
        if (sel !== old.sel || P.length !== old.P.length) return false
        for (var j = 0; j < P.length; j++)
            if (P[j][0] !== old.P[j][0] || Math.abs(P[j][1] - old.P[j][1]) >= 0.5 || Math.abs(P[j][2] - old.P[j][2]) >= 0.5) return false
        return true
    }
    function _notePainted() {
        var P = []; for (var i = 0; i < _proj.length; i++) P.push([_proj[i].b.id, _proj[i].sx, _proj[i].sy])
        _paintedKey = { P: P, sel: selectedId ? readoutFor(selectedId).join("|") : "" }
    }
    function invalidate() { _dirtyGeom = true; requestLayout() }

    // ---- interaction (30fps cap while dragging; zero timers at idle) ----
    property bool _pending: false
    Timer { id: throttle; interval: 33; repeat: false; onTriggered: { root._pending = false; root.invalidate() } }
    function _throttledInvalidate() { if (!_pending) { _pending = true; throttle.start() } }

    onBodiesChanged: { _normAll(); if (!liveBodies) { _live = _bodies; _updateRows() } if (offsetActive) { _dirtyGeom = true; _layout() }   // playback: lay out now, in step with playPhase reset
         else if (_sameAsPainted()) _updateMoveInterval(); else invalidate() }
    Component.onCompleted: { _normAll(); _normLive(); _updateRows(); Qt.callLater(_logGlow) }
    onShowPlutoChanged: { if (!showPluto && selectedId && _findBody(selectedId) && !_findBody(selectedId).dv) select(""); _updateRows(); invalidate() }
    onHoloChanged: requestLayout(); onAccentChanged: requestLayout(); onDateTextChanged: requestLayout()
    onSelectedIdChanged: { selectedChanged(selectedId); requestLayout() }
    onWidthChanged: invalidate(); onHeightChanged: invalidate()
    onFgChanged: requestLayout(); onBgChanged: requestLayout(); onDimChanged: requestLayout()

    function _findBody(id) { for (var i = 0; i < _bodies.length; i++) if (_bodies[i].id === id) return _bodies[i]; return null }
    function select(id) { selectedId = id }
    function readoutFor(id) { var b = _findLive(id); return b ? readout(b) : [] }   // for the narrow-panel detail line
    function cycle(dir) {
        if (_dirtyGeom) _rebuild()
        var ids = _proj.map(function(p){ return p.b.id }); if (!ids.length) return
        var i = ids.indexOf(selectedId)
        select(ids[(i < 0 ? (dir > 0 ? 0 : ids.length-1) : (i + dir + ids.length) % ids.length)])
    }
    function zoom(f) { maxAU = Math.max(0.5, Math.min(200, maxAU / f)); invalidate() }
    function pickAt(x, y) {
        var best = "", bd = 64 // 8px radius
        for (var i = 0; i < _proj.length; i++) { var p = _proj[i], dx = p.sx-x, dy = p.sy-y, d = dx*dx+dy*dy; if (d < bd) { bd = d; best = p.b.id } }
        return best
    }

    signal refreshRequested()   // r: ask Panel.qml to refresh the ephemeris (non-blocking)
    Keys.onPressed: function(e) {
        switch (e.key) {
        case Qt.Key_Space: showNames = !showNames; break   // names + leaders on/off (dots, orbits stay; slots kept)
        case Qt.Key_Period: playToggleRequested(); break
        case Qt.Key_BracketLeft: speedStepRequested(-1); break
        case Qt.Key_BracketRight: speedStepRequested(1); break
        case Qt.Key_Left: case Qt.Key_H: azimuth -= 5; _slotEpoch++; invalidate(); break
        case Qt.Key_Right: case Qt.Key_L: azimuth += 5; _slotEpoch++; invalidate(); break
        case Qt.Key_Up: tilt = Math.min(90, tilt + 5); _slotEpoch++; invalidate(); break
        case Qt.Key_Down: tilt = Math.max(0, tilt - 5); _slotEpoch++; invalidate(); break
        case Qt.Key_Plus: case Qt.Key_Equal: zoom(1.25); break
        case Qt.Key_Minus: zoom(0.8); break
        case Qt.Key_Tab: case Qt.Key_J: cycle(1); break
        case Qt.Key_Backtab: case Qt.Key_K: cycle(-1); break
        case Qt.Key_G: holoToggleRequested(); break   // never assign holo here: it would cut the binding from the panel
        case Qt.Key_0: if (offsetActive) liveRequested(); else resetView(); break
        case Qt.Key_R: refreshRequested(); invalidate(); break   // Panel.qml: manualRefresh()
        case Qt.Key_Escape: if (selectedId === "") closeRequested(); else select(""); break
        case Qt.Key_P: showPluto = !showPluto; break
        case Qt.Key_N: showNames = !showNames; break
        default: return
        }
        e.accepted = true
    }

    MouseArea {
        anchors.fill: parent
        property real px; property real py; property bool moved
        onPressed: function(m) { px = m.x; py = m.y; moved = false; root.forceActiveFocus() }
        onPositionChanged: function(m) {
            var dx = m.x - px, dy = m.y - py
            if (Math.abs(dx) + Math.abs(dy) > 2) moved = true
            root.azimuth += dx * 0.4; root.tilt = Math.max(0, Math.min(90, root.tilt - dy * 0.4))
            px = m.x; py = m.y; root._slotEpoch++; root._throttledInvalidate()
        }
        onReleased: function(m) { if (!moved) root.select(root.pickAt(m.x, m.y)) }
        onWheel: function(w) { root.zoom(w.angleDelta.y > 0 ? 1.15 : 1/1.15) }
    }
    PinchHandler { target: null; onScaleChanged: function(d) { root.zoom(d) } }

    Canvas {   // orbit layer: orbit polylines (+ holo halo) and the selected trail
        id: orbitLayer
        objectName: "orbitLayer"
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        property string key: ""
        layer.enabled: root.glowFx
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: root.holoGlow; shadowOpacity: 1; shadowBlur: 0.7; blurMax: 20; shadowHorizontalOffset: 0; shadowVerticalOffset: 0; brightness: 0.08 }
        onPaint: {
            var c = getContext("2d"); c.reset()
            if (!(width > 0) || !(height > 0)) return
            c.strokeStyle = root.ink
            var orb = function(){ root._orbits.forEach(function(o){ c.beginPath(); c.moveTo(o[0][0], o[0][1]); for (var j = 1; j < o.length; j++) c.lineTo(o[j][0], o[j][1]); c.stroke() }) }
            if (root.haloOn) { c.lineWidth = 6; c.globalAlpha = 0.06; orb() }   // holo: soft static halo under the 2 px orbit
            c.lineWidth = 1; c.globalAlpha = root.holo ? 0.55 : 0.40; orb()
            root._trail.forEach(function(g){ c.globalAlpha = g[4]; c.lineWidth = g[5]; c.beginPath(); c.moveTo(g[0], g[1]); c.lineTo(g[2], g[3]); c.stroke() })
        }
    }
    Rectangle {   // card backing: the orbit layer turns under it, so the card area is masked (bg), not clipped
        objectName: "cardMask"
        visible: root.cardRect.length === 4
        x: visible ? root.cardRect[0] : 0; y: visible ? root.cardRect[1] : 0
        width: visible ? root.cardRect[2] : 0; height: visible ? root.cardRect[3] : 0
        radius: 6; color: root.cardBase
    }
    Canvas {   // static layer: range rings, ring labels, info card (spec written by `canvas` below)
        id: staticLayer
        objectName: "staticLayer"
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        property string key: ""
        property string trailKey: ""
        property var spec: null
        onPaint: {
            var c = getContext("2d"), S = spec; c.reset(); if (!S || !(width > 0) || !(height > 0)) return
            var cx = width / 2, cy = height / 2, A = S.A
            c.lineWidth = 1; c.strokeStyle = root.ink; c.fillStyle = root.ink
            c.save()
            if (S.card) { var k = S.card; c.beginPath(); c.rect(0, 0, width, height); c.rect(k[0] + k[2], k[1], -k[2], k[3]); c.clip() }
            c.font = "11px " + S.F
            S.rings.forEach(function(g){
                if (g[4] && g[4].length) { c.globalAlpha = A.ring; var P = g[4]; c.beginPath(); c.moveTo(P[0][0], P[0][1]); for (var j = 1; j < P.length; j++) c.lineTo(P[j][0], P[j][1]); c.closePath(); c.stroke() }
                if (g[1]) { c.globalAlpha = A.ringText; c.fillText(g[1], g[2], g[3]) }
            })
            c.restore()
            // ---- info card: 6% backing + 28% outline, on an area the scene never paints
            var card = S.card ? { x: S.card[0], y: S.card[1], w: S.card[2], h: S.card[3] } : null, F = S.F, cardRows = S.cardRows
            if (card) {
                c.globalAlpha = 0.06; c.beginPath(); c.roundedRect(card.x, card.y, card.w, card.h, 6, 6); c.fill()
                c.globalAlpha = 0.28; c.beginPath(); c.roundedRect(card.x + .5, card.y + .5, card.w - 1, card.h - 1, 6, 6); c.stroke()
                c.font = "bold 14px " + F; c.globalAlpha = 1; c.fillText(S.cardName, card.x + 12, card.y + 20)
                c.font = "13px " + F
                for (var ri = 0; ri < cardRows.length; ri++) {
                    var yy = card.y + 40 + ri * 16, dimRow = cardRows[ri][0] === "src"
                    c.globalAlpha = dimRow ? 0.4 : A.text; c.fillText(cardRows[ri][0], card.x + 12, yy)
                    c.globalAlpha = dimRow ? 0.5 : 0.95; c.fillText(cardRows[ri][1], card.x + card.w - 12 - c.measureText(cardRows[ri][1]).width, yy)
                }
            }
        }
    }
    // ---- scene layout. Runs the label/marker placement and records the moving marks (dots, selected
    // ring, names, footer) as plain QML items below; rings, orbits, trail and card go to staticLayer.
    // No full-size Canvas is re-rasterised per playback frame. `c` is a recording shim with the
    // Context2D calls the placement code uses (measureText via FontMetrics).
    property int layoutRuns: 0          // QA counter: scene updates (paints) of the moving layer
    property var sceneDots: []          // unused since bodies moved to sceneBodies (kept for API compatibility)
    property var sceneBodies: []        // [{id, name, x, y (keyframe B), th0, dth, m0, m1 (segment), a (ring AU), r, op, sel, lead, ax, ay}]
    property bool interp: false         // bodies are drawn inside the A -> B segment at playPhase (false on jumps: snap to B)
    property real playPhase: 1          // Panel.qml: 0..1 inside the playback keyframe segment A -> B (set every frame)
    property real playSegDays: 0        // Panel.qml: segment length B - A in days (Hermite tangent scale); 0 = linear
    // Motion updates arrive on a fixed cadence (Panel.qml motionHz), so every update moves the dots: the gate only skips
    // a frame where nothing moved visibly at all (< 0.02 px; e.g. Neptune alone), never delays a step (even pacing).
    property real moveEpsPx: 0.02
    readonly property real nameSpacing: 1   // letter spacing of names (px)
    readonly property real leaderAlpha: holo ? 0.24 : 0.20   // lighter leaders (less clutter)
    property var _prevPos: null
    property var _slotCache: null
    // QA: per body {name, x, y} in panel pixels. Frame targets set by each layout; qaDotsNow() reads the
    // interpolated on-screen positions (kept off a per-frame binding so playback pays nothing for QA).
    property var qaDots: []
    property var qaLeaders: []   // QA: [{name, x1, y1 (slot end), x2, y2 (dot target)}] moving leader lines, for masks
    property bool leadersEnabled: true
    property bool interpEnabled: true
    function qaDotsNow() { var r = []; for (var i = 0; i < dotRep.count; i++) { var b = dotRep.itemAt(i); if (b) r.push({ name: b.d.name, x: b.x + b.d.r, y: b.y + b.d.r }) } return r }
    // Each dot stays on its ring (radius d.a) at longitude th(k), k = playPhase: cubic Hermite from keyframe A (th0, tangent m0)
    // to keyframe B (th0 + dth, tangent m1); tangents = angular rate x segment days. Exact at both keyframes, C1 across them.
    function _thAt(d, k) {
        var k2 = k * k, k3 = k2 * k
        return d.th0 + (k3 - 2 * k2 + k) * d.m0 + (3 * k2 - 2 * k3) * d.dth + (k3 - k2) * d.m1
    }
    function _posAt(d, k) {
        if (!(d.a > 0)) return [d.x, d.y]
        var th = _thAt(d, k)
        if (_tiltEff === 90) { var g = th + azimuth * Math.PI / 180; return [width / 2 + d.rpx * Math.cos(g), height / 2 - d.rpx * Math.sin(g)] }   // flat: _project() of a ring point, closed form
        return _project(d.a * Math.cos(th), d.a * Math.sin(th), 0)
    }
    function _placeOne(it, k) {
        var d = it.d; if (d.th0 === undefined) return
        var p = _posAt(d, k)
        it.x = p[0] - d.r; it.y = p[1] - d.r
        return p
    }
    property bool textLayer: false
    function _lead(ld, d, px, py) {
        ld.tx = px; ld.ty = py
        var dx = px - d.ax, dy = py - d.ay, L = Math.sqrt(dx * dx + dy * dy), w = Math.max(0, L - d.r - 6)
        ld.x = d.ax; ld.y = d.ay - 0.5
        ld.width = w; ld.rotation = Math.atan2(dy, dx) * 180 / Math.PI
    }
    // Per frame: dots move once any is >= moveEpsPx off; a leader (which stops 6 px short of its dot, at 0.20 opacity) follows
    // its dot once that is >= leaderEpsPx from the end it was drawn for. force (layout): everything is set.
    readonly property real leaderEpsPx: 1
    property int placeRuns: 0           // QA counter: frames that moved the items
    property var _P: []
    property real _kPlaced: 0           // phase the items were last placed at
    property real _vMax: 1e9            // px per unit phase: upper bound on any dot's speed this segment (set by a forced place)
    function _place(force) {
        var k = interp ? playPhase : 1, n = dotRep.count, P = _P, far = !!force
        if (!far && Math.abs(k - _kPlaced) * _vMax < moveEpsPx) return   // no dot can be eps off yet: skip the per-dot work
        P.length = n
        for (var i = 0; i < n; i++) {
            var it = dotRep.itemAt(i); P[i] = null; if (!it || it.d.th0 === undefined) continue
            var p = _posAt(it.d, k); P[i] = p
            if (!far && (Math.abs(p[0] - it.d.r - it.x) >= moveEpsPx || Math.abs(p[1] - it.d.r - it.y) >= moveEpsPx)) far = true
        }
        if (!far) return
        placeRuns++; _kPlaced = k
        if (force) {   // Hermite slope bound: |h'| <= 1.5|dth| + |m0| + |m1| (flat ring: px = rpx * angle; tilted: 1.5x margin)
            var vm = 0
            for (var b = 0; b < n; b++) { var e = dotRep.itemAt(b); if (!e || !(e.d.a > 0)) continue
                vm = Math.max(vm, e.d.rpx * (1.5 * Math.abs(e.d.dth) + Math.abs(e.d.m0) + Math.abs(e.d.m1))) }
            _vMax = vm * (_tiltEff === 90 ? 1 : 1.5)
        }
        for (var j = 0; j < n; j++) { var q = P[j]; if (!q) continue; var d = dotRep.itemAt(j); d.x = q[0] - d.d.r; d.y = q[1] - d.d.r
            var ld = leaderRep.itemAt(j)
            if (ld && ld.d.lead && (force || Math.abs(q[0] - ld.tx) >= leaderEpsPx || Math.abs(q[1] - ld.ty) >= leaderEpsPx)) _lead(ld, ld.d, q[0], q[1]) }
    }
    function _leadAll() { for (var i = 0; i < leaderRep.count; i++) { var ld = leaderRep.itemAt(i); if (ld) _lead(ld, ld.d, ld.d.x, ld.d.y) } }
    onPlayPhaseChanged: _place(false)
    // glow (holo halo under orbits and dots) on/off, for CPU A/B; never used in plain
    property bool glowEnabled: true
    readonly property bool glowOn: holo && glowEnabled
    readonly property bool haloOn: glowOn && !glowFx
    onHaloOnChanged: { orbitLayer.key = ""; orbitLayer.requestPaint() }
    property string _textsKey: ""
    // dot radius by body (Asteroid Radar range 1.5-6 px): Sun 5, giants 4, ice giants 3.5, rocky 3, dwarfs 2.5
    function _dotR(b) { return b.type === "star" ? 5 : ({ jupiter: 4, saturn: 4, uranus: 3.5, neptune: 3.5 })[b.id] || (b.type === "planet" ? 3 : 2.5) }
    property var sceneTexts: []         // [{s, x, y(baseline), f(font key), a}]
    property var _trail: []
    function requestLayout() { Qt.callLater(root._layout) }
    FontMetrics { id: fm10; font.family: root.fontFamily; font.pixelSize: 11 }
    FontMetrics { id: fm11; font.family: root.fontFamily; font.pixelSize: 13 }
    FontMetrics { id: fm10b; font.family: root.fontFamily; font.pixelSize: 15; font.bold: true }
    FontMetrics { id: fm11b; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true }
    FontMetrics { id: fm13b; font.family: root.fontFamily; font.pixelSize: 14; font.bold: true }
    function _fm(f) { return f.indexOf("bold 14") === 0 ? fm13b : f.indexOf("bold 15") === 0 ? fm10b : f.indexOf("13px") === 0 ? fm11 : fm10 }
    property var _shimObj: null
    function _shim() {   // built once; each layout only resets its buffers (no per-frame closures)
        if (_shimObj) { _shimObj._clear(); return _shimObj }
        var D = [], T = [], L = [], path = [], c = { font: "10px", globalAlpha: 1, lineWidth: 1, fillStyle: null, strokeStyle: null }
        c._clear = function() { D = []; T = []; L = []; path = []; c.font = "10px"; c.globalAlpha = 1; c.lineWidth = 1 }
        _shimObj = c
        c.reset = function() {}; c.fillRect = function() {}; c.save = function() {}; c.restore = function() {}; c.clip = function() {}; c.rect = function() {}
        c.beginPath = function() { path = [] }
        c.arc = function(x, y, r) { path.push({ arc: [x, y, r] }) }
        c.moveTo = function(x, y) { path.push({ m: [x, y] }) }
        c.lineTo = function(x, y) { path.push({ l: [x, y] }) }
        c.fill = function() { path.forEach(function(p){ if (p.arc) D.push({ x: p.arc[0], y: p.arc[1], r: p.arc[2], a: c.globalAlpha, fill: true }) }) }
        c.stroke = function() {
            var last = null
            path.forEach(function(p){ if (p.arc) D.push({ x: p.arc[0], y: p.arc[1], r: p.arc[2], a: c.globalAlpha, fill: false })
                                      else if (p.m) last = p.m; else if (p.l && last) { L.push([last[0], last[1], p.l[0], p.l[1], c.globalAlpha, c.lineWidth]); last = p.l } })
        }
        c.fillText = function(s, x, y) { T.push({ s: s, x: x, y: y, f: c.font, a: c.globalAlpha }) }
        c.measureText = function(s) { return { width: root._fm(c.font).advanceWidth(s) } }
        c.T_last = function() { return T[T.length - 1] }
        c.out = function() { return { D: D, T: T, L: L } }
        return c
    }
    function _layout() {
        root.layoutRuns++
        if (true) {
            if (root._dirtyGeom) root._rebuild()
            if (!root.offsetActive) root._notePainted(); else root._paintedKey = null
            var c = root._shim(), W = root.width, H = root.height, cx = W/2, cy = H/2
            var F = root.fontFamily, ink = root.ink, M = 8, PAD = 4
            // Opacity steps (one hue per mode). Holo is a touch softer on lines, like the reference.
            var A = root.holo ? { ring: 0.10, ringText: 0.40, orbit: 0.30, dot: 1.0, name: 1.0, text: 1.0 }
                              : { ring: 0.12, ringText: 0.45, orbit: 0.30, dot: 1.0, name: 1.0, text: 1.0 }
            function hit(a, b) { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h }
            function grow(r, g) { return { x: r.x - g, y: r.y - g, w: r.w + 2*g, h: r.h + 2*g } }
            function inside(r) { return r.x >= M && r.y >= M && r.x + r.w <= W - M && r.y + r.h <= H - M }
            c.reset(); if (root.bg.a > 0) { c.fillStyle = root.bg; c.fillRect(0, 0, W, H) }
            c.lineWidth = 1; c.strokeStyle = ink; c.fillStyle = ink
            var blocked = []   // boxes text must not overlap

            // ---- bottom-left: date · log scale
            c.font = "13px " + F; c.globalAlpha = A.text
            var foot = (root.dateText ? root.dateText + " \u00b7 " : "") + "log scale"
            c.fillText(foot, M + 8, H - M - 4)
            var s = null
            if (root.selectedId) for (var k = 0; k < root._proj.length; k++) if (root._proj[k].b.id === root.selectedId) s = root._proj[k]
            // Footer, card and ring labels depend only on view settings and LIVE values: during playback they are
            // computed once and reused every frame (key below), not re-measured per frame.
            var card = null, cardRows = []
            var stk = [W, H, F, String(ink), root.holo, root.dateText, root.selectedId, root.showCard, root.showRings, root.maxAU, root._liveRev, String(root.bg), s ? 1 : 0, root._geomKey, root.showNames, root._proj.length, root.glowOn].join("|")
            var STC = root._stCache
            var slots = {}
            if (root.offsetActive && STC && STC.k === stk) { blocked = STC.blocked.slice(); card = STC.card; cardRows = STC.cardRows; slots = STC.slots }
            else {
            blocked.push({ x: M, y: H - M - 16, w: c.measureText(foot).width + 8, h: 16, nm: true })


            // ---- info card geometry (bottom right). Lines come from readout(); on small panels the
            // card sheds low-priority lines so it fits, and it sits above the footer if they would meet.
            if (s && root.showCard) {
                var lb = root._findLive(s.b.id) || s.b, L = root.readout(lb), rows = [], title = s.b.name
                for (var li = 1; li < L.length; li++) rows.push([L[li].slice(0, 6).trim(), L[li].slice(6).trim()])
                var srcName = lb.src && lb.src.source ? String(lb.src.source) : ""
                if (srcName) rows.push(["src", srcName])
                var shed = ["per", "rad", "", "light", "src"]   // dropped first -> last ("" = km line)
                var footW = blocked[0].x + blocked[0].w
                var ck = JSON.stringify(rows) + title + W + "x" + H + "|" + footW + F
                function measure() {
                    c.font = "13px " + F
                    var vw = 0, lw = 0
                    rows.forEach(function(r){ vw = Math.max(vw, c.measureText(r[1]).width); lw = Math.max(lw, c.measureText(r[0]).width) })
                    c.font = "bold 14px " + F
                    var cw = Math.max(lw + 14 + vw, c.measureText(title).width) + 24, ch = 30 + rows.length * 16 + 6
                    var x = W - M - 8 - cw, y = H - M - ch
                    if (x < footW + 8) y = H - M - 20 - ch      // footer clear: lift the card above it
                    return { x: x, y: y, w: cw, h: ch }
                }
                if (root._cardCache && root._cardCache.k === ck) { card = root._cardCache.card; rows = root._cardCache.rows; shed = [] }   // live values: same card every playback frame
                else card = measure()
                while ((card.h > (H - 2 * M) * 0.42 || card.x < M + 8) && shed.length) {
                    var drop = shed.shift(), n = rows.length
                    rows = rows.filter(function(r){ return r[0] !== drop })
                    if (rows.length !== n) card = measure()
                }
                cardRows = rows
                root._cardCache = { k: ck, card: card, rows: rows }
                blocked.push(card)
            }

            // ---- name slots: every name always shown, in a fixed slot beside the scope (left column: first half
            // of the bodies, right column: the rest), joined to its dot by a thin leader line. Slots depend only on
            // the view (size, zoom, rotation, card, body set), never on the frame, so a name never moves or hides.
            var slotBoxes = []
            // slots are cached on the view alone (size, font, body set, orbit geometry, card), not on time: play,
            // pause and live updates never re-deal them
            var slk = [W, H, F, root._geomKey, root._proj.map(function(p){ return p.b.id }).join(","), card ? [card.x, card.y, card.w, card.h].join(",") : ""].join("|")
            if (root._slotCache && root._slotCache.k === slk) { slots = root._slotCache.slots; slotBoxes = root._slotCache.boxes; slotBoxes.forEach(function(r){ blocked.push(r) }) }
            else {
                var LS = root.nameSpacing, nfont = "bold 15px " + F, RH = 20
                var nb = root._proj.map(function(p){ return p.b })
                // (the static key holds the bodies' set, not their places, so slots stay fixed while playing)
                var ex = { x0: cx, x1: cx }
                // horizontal extent over every azimuth (rotation sweeps the orbits; the columns stay clear of all of them)
                root._orbits.forEach(function(o){ for (var q = 0; q < o.length; q += 3) { var rr = Math.sqrt((o[q][0] - cx) * (o[q][0] - cx) + Math.pow((o[q][1] - cy) / Math.max(0.2, Math.sin(root._tiltEff * Math.PI / 180)), 2)); if (cx - rr < ex.x0) ex.x0 = cx - rr; if (cx + rr > ex.x1) ex.x1 = cx + rr } })
                root._proj.forEach(function(p){ ex.x0 = Math.min(ex.x0, p.sx); ex.x1 = Math.max(ex.x1, p.sx) })
                // sides and row order follow where the dots are when the slots are made (fewer crossing leaders); they
                // then stay put for the whole run, even as the dots move.
                var at = {}; root._proj.forEach(function(p){ at[p.b.id] = [p.sx, p.sy] })
                var byX = nb.slice().sort(function(a, b){ return at[a.id][0] - at[b.id][0] || (a.id < b.id ? -1 : 1) })
                var byY = function(a, b){ return at[a.id][1] - at[b.id][1] || (a.id < b.id ? -1 : 1) }
                var nL = Math.ceil(nb.length / 2), colL = byX.slice(0, nL).sort(byY), colR = byX.slice(nL).sort(byY)
                var wOf = function(b){ return root._tw(nfont, b.name) + LS * b.name.length }
                var wL = 0, wR = 0; colL.forEach(function(b){ wL = Math.max(wL, wOf(b)) }); colR.forEach(function(b){ wR = Math.max(wR, wOf(b)) })
                var xL = Math.max(M + 4 + wL, Math.min(ex.x0 - 14, cx - 40)), xR = Math.min(W - M - 4 - wR, Math.max(ex.x1 + 14, cx + 40))
                var yL = cy - nL * RH / 2, yR = cy - colR.length * RH / 2
                if (card && xR + wR > card.x && yR + colR.length * RH > card.y - 4) yR = card.y - 4 - colR.length * RH   // right column sits above the card
                yL = Math.max(M, Math.min(H - M - 22 - nL * RH, yL)); yR = Math.max(M, yR)
                colL.forEach(function(b, i){ var w = wOf(b), y = yL + i * RH
                    slots[b.id] = { x: xL - w, y: y + 11, w: w, ax: xL + 4, ay: y + 6.5 }; slotBoxes.push({ x: xL - w, y: y + 1, w: w, h: 12, nm: true }) })
                colR.forEach(function(b, i){ var w = wOf(b), y = yR + i * RH
                    slots[b.id] = { x: xR, y: y + 11, w: w, ax: xR - 4, ay: y + 6.5 }; slotBoxes.push({ x: xR, y: y + 1, w: w, h: 12, nm: true }) })
                slotBoxes.forEach(function(r){ blocked.push(r) })   // ring labels give way to names
                root._slotCache = { k: slk, slots: slots, boxes: slotBoxes }
            }
            // ---- range rings + small AU labels (lower right of each ring) + orbits: time-independent, so
            // they live on `staticLayer` below and repaint only when this spec changes (not per playback frame).
            var ringSpec = []
            if (root.showRings) {
                c.font = "11px " + F
                ;[1, 5, 10, 30].forEach(function(au){
                    if (au > root.maxAU) return
                    var r = root._scale(au)
                    var t = au + " AU", tw = c.measureText(t).width
                    // ring = projected circle in the ecliptic (an ellipse with perspective; yaw-invariant). Label sits where the ring crosses screen angle -0.3 rad (lower right), like Asteroid Radar.
                    var P = [], az0 = root.azimuth * Math.PI/180
                    for (var q = 0; q <= 64; q++) { var th = q / 64 * 2*Math.PI; P.push(root._project(au*Math.cos(th), au*Math.sin(th), 0).map(Math.round)) }
                    var lp = root._project(au*Math.cos(-az0 - 0.3), au*Math.sin(-az0 - 0.3), 0)
                    var lx = Math.round(lp[0]) + 4, ly = Math.round(lp[1]) + 4
                    var box = { x: lx, y: ly - 10, w: tw, h: 12 }
                    var clear = inside(box)   // hide labels that would touch another label, the footer or the card
                    for (var bq = 0; clear && bq < blocked.length; bq++) if (hit(grow(box, 3), blocked[bq])) clear = false
                    ringSpec.push([r, clear ? t : "", lx, ly, P])
                    if (clear) { box.nm = true; blocked.push(box) }
                })
            }
            var spec = { rings: ringSpec, card: card ? [card.x, card.y, card.w, card.h] : null, cardName: s ? s.b.name : "", cardRows: cardRows, A: A, ink: String(ink), F: F, ok: root._orbitsKey, W: W, H: H, glow: root.glowOn }
            var sk = JSON.stringify(spec)
            var sk2 = String(sk.replace(/"ok":"[^"]*",?/, ""))
            if (sk2 !== staticLayer.key) { staticLayer.key = sk2; staticLayer.spec = spec; staticLayer.requestPaint() }
            root._stCache = { k: stk, blocked: blocked.slice(), card: card, cardRows: cardRows, slots: slots }
            }
            var ok2 = [root._orbitsKey, root.haloOn, String(ink), W, H].join("|")
            if (ok2 !== orbitLayer.key) { orbitLayer.key = ok2; orbitLayer.requestPaint() }
            // Scene layers never paint under the card (no opaque mask; card fill stays at 6%).
            // ---- bodies: filled dot + 1 px ring (0.6), selected ring, leader line to the name slot. Positions are
            // the frame's targets; the delegates glide to them over one frame interval (interpolation), except on a
            // jump (loop wrap, time set by hand), which snaps.
            var markers = [], out = [], labels = [], texts = []
            // Segment per body: previous keyframe (A: longitude, angular rate) -> this one (B). The longitude step is
            // unwrapped to the turn count the angular rates predict, so fast bodies (> 180 deg per segment) never go backwards.
            var jump = root._prevPos === null, D = root.playSegDays
            var pos = {}
            root._proj.forEach(function(p){
                var b = p.b, q = root._prevPos && root._prevPos[b.id]
                var th1 = Math.atan2(b.y, b.x), rr = b.x * b.x + b.y * b.y, om1 = rr > 0 ? (b.x * (b.vy || 0) - b.y * (b.vx || 0)) / rr : 0   // rad/day
                if (!q) jump = true
                pos[b.id] = [th1, om1]
                var th0 = q ? q[0] : th1, om0 = q ? q[1] : om1, dth = th1 - th0, m0 = 0, m1 = 0
                dth -= 2 * Math.PI * Math.round(dth / (2 * Math.PI))
                if (q && D > 0) {
                    var pred = 0.5 * (om0 + om1) * D
                    dth += 2 * Math.PI * Math.round((pred - dth) / (2 * Math.PI))
                    // tangents from the Ephemeris rates when they agree with the step (else linear: constant rate in the segment)
                    if ((om0 !== 0 || om1 !== 0) && Math.abs(pred - dth) <= 0.25 * Math.abs(dth) + 0.01) { m0 = om0 * D; m1 = om1 * D } else { m0 = dth; m1 = dth }
                } else { m0 = dth; m1 = dth }
                var r = root._dotR(b), sl = slots[b.id] || null
                var ra = b.type === "star" ? 0 : root._orbitR(b)
                out.push({ id: b.id, name: b.name, x: p.sx, y: p.sy, th0: th0, dth: dth, m0: m0, m1: m1, a: ra, rpx: ra > 0 ? root._scale(ra) : 0, r: r,
                           op: p === s ? 1 : (b.type === "star" ? 0.95 : A.dot), sel: p === s,
                           lead: !!sl, ax: sl ? sl.ax : 0, ay: sl ? sl.ay : 0 })
                var e = r + 3.5
                markers.push({ x: p.sx - e, y: p.sy - e, w: 2 * e, h: 2 * e, id: p.b.id })
                if (p === s) markers.push({ x: p.sx - r - 8, y: p.sy - r - 8, w: 2 * r + 16, h: 2 * r + 16, ring: true, id: p.b.id })
                if (sl) labels.push([p.b.name, sl.x, sl.y - 10, sl.w, 12])
            })
            root._prevPos = pos
            if (root.wrapFade || !root.playing) jump = true
            // names: one Text per body in _proj order (fixed slots), then the footer
            root._proj.forEach(function(p){ var sl = slots[p.b.id]
                texts.push({ e: p.b.id === "earth", s: p.b.name, x: sl ? sl.x : 0, y: sl ? sl.y : 0, f: "bold 15px " + F, a: sl ? (p === s ? 1 : A.name) : 0, ls: root.nameSpacing, nm: true }) })
            var o = c.out()
            o.T.forEach(function(t){ texts.push(t) })   // footer
            root.placedLabels = labels
            root.heldLabels = []
            root.placedMarkers = markers
            var cr = card ? [card.x, card.y, card.w, card.h] : []
            if (String(cr) !== String(root.cardRect)) root.cardRect = cr
            root.interp = !jump && root.interpEnabled
            root.sceneBodies = out
            root._place(true)   // dots + leaders at the current phase
            root.qaLeaders = out.filter(function(b){ return b.lead }).map(function(b){ return { name: b.name, x1: b.ax, y1: b.ay, x2: b.x, y2: b.y } })
            root.qaDots = out.map(function(b){ return { name: b.name, x: b.x, y: b.y } })
            var tk = JSON.stringify(texts)
            if (tk !== root._textsKey) { root._textsKey = tk; root.sceneTexts = texts }   // static between view changes
            // selected trail (live only; no trails during playback) goes to the static layer
            var L = root._trailLines(s)
            var lk = L.length ? JSON.stringify(L) : "[]"
            if (lk !== staticLayer.trailKey) { staticLayer.trailKey = lk; root._trail = L; orbitLayer.requestPaint() }
        }
    }
    // loop-wrap fade of the bodies only (dots, rings, leaders); names never fade
    property real bodyFade: wrapFade ? 0 : 1
    Behavior on bodyFade { NumberAnimation { duration: 280 } }
    // Holo glow for the moving layer (AR #3fd8ff, blur 0.7, brightness 0.08) at half resolution: a half-size
    // capture of `scene` is blurred + colorized in a half-size MultiEffect scaled x2 (blurMax 10 = AR's 20 px on
    // screen), drawn under the crisp scene.
    ShaderEffectSource {
        id: sceneHalf
        sourceItem: root.glowFx ? scene : null
        width: Math.max(1, Math.round(root.width / 2)); height: Math.max(1, Math.round(root.height / 2))
        textureSize: Qt.size(width, height)
        visible: false; hideSource: false; live: true
    }
    MultiEffect {
        objectName: "sceneGlow"
        visible: root.glowFx
        source: root.glowFx ? sceneHalf : null
        width: sceneHalf.width; height: sceneHalf.height
        transformOrigin: Item.TopLeft; scale: 2
        blurEnabled: true; blur: 0.7; blurMax: 10
        colorization: 1; colorizationColor: root.holoGlow; brightness: 0.08
    }
    Item {   // moving layer: flat Rectangles (dots, rings, leaders) + name Texts
    id: scene
    objectName: "scene"
    anchors.fill: parent
    // Bodies are moved imperatively (no per-frame bindings): _place() sets each dot's x/y on its ring at k = playPhase.
    // Ring and selection ring are children of the dot, so one x/y pair per body (plus its leader) per frame is all that changes.
    Repeater {   // leaders: slot anchor -> 6 px short of the drawn dot (geometry set with the dot, every moving frame)
        id: leaderRep
        model: root.sceneBodies.length
        delegate: Rectangle {
            id: ld
            objectName: "leader"
            required property int index
            readonly property var d: root.sceneBodies[ld.index] || ({ x: 0, y: 0, r: 0, sel: false, lead: false, ax: 0, ay: 0 })
            visible: ld.d.lead && root.leadersEnabled && root.showNames   // Space / n: names + leaders off, slots kept
            height: 1; transformOrigin: Item.Left   // x, y, width, rotation set by _lead()
            property real tx: 0; property real ty: 0   // dot centre this leader was drawn for
            Component.onCompleted: root._lead(ld, ld.d, ld.d.x, ld.d.y)
            color: root.ink; opacity: (ld.d.sel ? 0.6 : root.leaderAlpha) * root.bodyFade
            antialiasing: true
        }
    }
    Repeater {   // dots (filled) + 1 px ring at 0.6 + selected ring; x/y set by _place()
        id: dotRep
        model: root.sceneBodies.length
        delegate: Rectangle {
            id: dt
            objectName: "dot"
            required property int index
            readonly property var d: root.sceneBodies[dt.index] || ({ x: 0, y: 0, r: 0, a: 0, op: 0, sel: false })
            width: 2 * dt.d.r; height: width; radius: dt.d.r
            readonly property color c: dt.d.id === "earth" ? root.earthInk : root.ink
            z: dt.d.id === "earth" ? -1 : 0   // Earth under its neighbours: its amber ring never tints Venus/Mars
            color: dt.c; opacity: dt.d.op * root.bodyFade; antialiasing: true
            Component.onCompleted: { var p = root._placeOne(dt, root.interp ? root.playPhase : 1); var ld = leaderRep.itemAt(dt.index); if (p && ld && ld.d.lead) root._lead(ld, ld.d, p[0], p[1]) }
            Rectangle {
                readonly property real rr: dt.d.r + 2.5
                x: dt.d.r - rr; y: x; width: 2 * rr; height: width; radius: rr
                color: "transparent"; border.width: 1; border.color: dt.c; opacity: 0.6; antialiasing: true
            }
            Rectangle {
                visible: dt.d.sel
                readonly property real rr: dt.d.r + 6
                x: dt.d.r - rr; y: x; width: 2 * rr; height: width; radius: rr
                color: "transparent"; border.width: 1; border.color: dt.c; antialiasing: true
            }
        }
    }
    Repeater {   // names (fixed slots; never fade) + footer
        id: textRep
        model: root.sceneTexts.length
        delegate: Text {
            id: txt
            required property int index
            readonly property var t: root.sceneTexts[txt.index] || ({ s: "", x: 0, y: 0, f: "10px", a: 0 })
            readonly property var m: root._fm(txt.t.f)
            x: txt.t.x; y: txt.t.y - txt.m.ascent
            text: txt.t.s; color: txt.t.e ? root.earthInk : root.ink; opacity: txt.t.a
            visible: !txt.t.nm || root.showNames
            font.family: root.fontFamily; font.pixelSize: txt.m.font.pixelSize; font.bold: txt.m.font.bold
            font.letterSpacing: txt.t.ls || 0
            layer.enabled: root.textLayer   // cached texture: a collateral redraw blits it, no glyph re-rasterisation
        }
    }
    }
}
