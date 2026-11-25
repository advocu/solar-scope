// Solar Scope panel body: header, scope, table, hint. Pure QtQuick (no Quickshell types), so it
// also runs in the offscreen dev harness. One hue per mode: `fg` (plain) or `accent` (holo),
// opacity steps only. Layout follows the Asteroid Radar panel (MIT, (c) 2026 chanwook lee);
// see ATTRIBUTION.txt. No effects, glow or shaders.
import QtQuick
import "bodies-data.js" as BodiesData

Item {
    id: root
    // ---- in
    property var bodies: []
    property color fg: "#cacccc"
    property color accent: "#7fd4d4"
    property string fontFamily: "monospace"
    property bool showPluto: false
    property bool showNames: true
    property color background: "#101315"
    property bool holo: false
    property var lastUpdated: null     // epoch ms or null (Orbits.lastUpdated())
    property real now: Date.now()      // ticked by the host (1 s open / 60 s closed)
    property string statusText: ""     // Plugin Engineer's refreshStatus: secondary failure signal
    property string ephStatus: ""      // status.json status: "ok" | "error" | ""
    property var ephFetchedAt: null    // status.json fetchedAt (epoch ms) | null
    property string ephError: ""       // status.json lastError (sanitized; not displayed raw)
    property var staleBodies: []       // status.json staleBodies
    property alias selectedId: scope.selectedId
    property alias scope: scope
    property string playText: ""       // Panel.qml playback readout, "" when live
    property var liveBodies: null      // real-time bodies for table/card (playback draws `bodies` ahead)
    property bool offsetActive: false
    property bool wrapFade: false      // Panel.qml: playback loop wrap in progress (scene fades)
    property real playPhase: 1         // Panel.qml: 0..1 between playback keyframes
    property real playSegDays: 0       // Panel.qml: keyframe segment length (days)
    property bool playing: false       // Panel.qml: playback timer running (label hysteresis on)
    property real playbackOffsetMs: 0  // ms ahead of real time (0 = now)
    // ---- v1.1 pages (table only; the scope above is never touched)
    property int page: 1               // 1 = bodies in the scope, 2 = largest asteroids, 3 = beyond Neptune
    property bool showRoadster: false  // t: Tesla Roadster as a plain row at the end of page 1 (no dot)
    property var extraRows: []         // Panel.qml Extras.build(): [{id,name,short,page,size,dist,distEarth,speed,lightTime}], NaN = missing
    // ---- out
    signal playToggleRequested()
    signal holoToggleRequested()
    signal speedStepRequested(int d)
    signal liveRequested()
    signal refreshRequested()
    signal sourceLinkRequested(string url)   // header "JPL" click; Panel.qml opens it
    readonly property string horizonsBase: "https://ssd.jpl.nasa.gov/horizons/app.html"
    function horizonsUrl() {
        var list = BodiesData.bodies.bodies, id = scope.selectedId
        if (id) for (var i = 0; i < list.length; i++)
            if (list[i].id === id && list[i].horizons_id) return horizonsBase + "#/?id=" + encodeURIComponent(list[i].horizons_id)
        return horizonsBase
    }
    property real lastManualRefresh: 0   // Panel.qml manualRefreshAt (epoch ms of the last accepted manual refresh)
    property int debounceMs: 60000
    property string refreshHint: ""      // "refresh in 42s", shown ~2 s in the hint line
    signal closeRequested()            // Esc with nothing selected

    readonly property color holoTint: "#4cb4ff"   // holo: one fixed light-blue hue (#8eeeff family, bluer so faint strokes stay blue over dark backgrounds), whatever the theme accent
    readonly property color ink: holo ? holoTint : fg
    property bool active: true            // Panel.qml: opened (auto-rotation ticks only while open)
    readonly property color earthInk: scope.earthInk   // Earth's amber accent (scope dot/name + its table row)
    // QA: Earth-accent items in panel pixels (dot+ring, name, table row) - the only non-monochrome pixels in plain mode
    function qaAccentItems() {
        var r = [], a = scope.qaAccentItems()
        for (var i = 0; i < a.length; i++) { var q = scope.mapToItem(root, a[i].x, a[i].y); r.push({ kind: a[i].kind, x: q.x, y: q.y, w: a[i].w, h: a[i].h }) }
        for (var j = 0; j < table.count; j++) { var it = table.itemAtIndex(j); if (it && it.earth) { var p = it.mapToItem(root, 0, 0); r.push({ kind: "row", x: p.x, y: p.y, w: it.width, h: it.height }) } }
        return r
    }
    readonly property int pad: 16
    implicitWidth: 600; implicitHeight: 760

    // Adapted from asteroid-radar Model.js:187-196 (fmtRelative), MIT (c) 2026 chanwook lee.
    function fmtRelative(at, nowMs) {
        var s = Math.abs(at - nowMs) / 1000, t
        if (s < 3600) t = Math.max(1, Math.round(s / 60)) + "m"
        else if (s < 86400) t = Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
        else t = Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
        return at <= nowMs ? t + " ago" : "in " + t
    }
    function _two(n) { return (n < 10 ? "0" : "") + n }
    readonly property string dateText: {
        var d = new Date(now), days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days[d.getDay()] + " " + (d.getMonth() + 1) + "/" + d.getDate() + " " + _two(d.getHours()) + ":" + _two(d.getMinutes())
    }
    readonly property bool refreshFailed: ephStatus === "error" || (ephStatus === "" && statusText.indexOf("ERROR") === 0)
    // G18: status.json fetchedAt first, Orbits.lastUpdated() (live.json) as the fallback.
    readonly property var updatedAt: (typeof ephFetchedAt === "number" && isFinite(ephFetchedAt)) ? ephFetchedAt
                                   : (typeof lastUpdated === "number" && isFinite(lastUpdated)) ? lastUpdated : null
    readonly property bool narrow: width < 440
    readonly property bool stale: updatedAt !== null && now - updatedAt > 45 * 60000
    readonly property string sourceText: narrow
        ? (updatedAt !== null ? "JPL \u00b7 " + fmtRelative(updatedAt, now).replace(" ago", "") + (stale ? " \u00b7 stale" : "") : "JPL \u00b7 cached")
          + (refreshFailed ? " \u00b7 failed" : "")
        : (updatedAt !== null ? "JPL \u00b7 updated " + fmtRelative(updatedAt, now) + (stale ? " \u00b7 stale" : "") : "JPL \u00b7 cached")
          + (refreshFailed ? " \u00b7 refresh failed" : "")
    readonly property string errorTip: refreshFailed ? "JPL unreachable \u00b7 showing cached positions" : ""
    // Source of the selected body ("live" | "cache" | "kepler" ...), shown dim above the card.

    // ---- header
    Item {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: root.pad; rightMargin: root.pad; topMargin: 12 }
        height: 24
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.narrow ? "SOLAR" : "SOLAR SCOPE"; color: root.holo ? "#8eeeff" : Qt.lighter(root.ink, 1.12); opacity: 1   // brightest text on the panel (holo: AR fg)
            font { family: root.fontFamily; pixelSize: 18; bold: true; letterSpacing: 2 }
        }
        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 10
            Text {   // playback readout: shown only while playing or offset from live
                objectName: "playbackLabel"
                anchors.verticalCenter: parent.verticalCenter
                visible: root.playText !== ""
                text: root.narrow ? root.playText.replace(" days/s", "d/s") : root.playText
                color: root.ink; opacity: 0.8
                font { family: root.fontFamily; pixelSize: 12 }
            }
            Text {
                id: srcLabel
                anchors.verticalCenter: parent.verticalCenter
                text: root.playText !== "" ? "JPL" : root.sourceText; color: root.ink; opacity: 0.85
                font { family: root.fontFamily; pixelSize: 12 }
                HoverHandler { id: srcHover; enabled: root.errorTip !== "" }
                font.underline: srcLink.containsMouse
                MouseArea {
                    id: srcLink
                    objectName: "jplLink"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: root.sourceLinkRequested(root.horizonsUrl())
                }
            }
            Rectangle {   // HOLO pill: outline only, brighter when on
                id: pill
                anchors.verticalCenter: parent.verticalCenter
                width: pillText.implicitWidth + 16; height: 18; radius: 9
                color: "transparent"; border.width: 1
                border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, root.holo ? 0.9 : 0.3)
                Text {
                    id: pillText; anchors.centerIn: parent; text: "HOLO"
                    color: root.ink; opacity: root.holo ? 1 : 0.45
                    font { family: root.fontFamily; pixelSize: 11; bold: true; letterSpacing: 1 }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.holoToggleRequested() }
            }
        }
    }

    // ---- scope
    SolarScopeView {
        id: scope
        anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: root.narrow ? detail.top : sep.top; topMargin: 4; bottomMargin: 6 }
        showCard: !root.narrow   // narrow panels: the card moves out of the scope into `detail` below
        bodies: root.bodies
        fg: root.fg; accent: root.holoTint; holo: root.holo
        bg: "transparent"
        cardBase: root.background
        fontFamily: root.fontFamily
        showPluto: root.showPluto
        showNames: root.showNames
        onCloseRequested: root.closeRequested()
        dateText: root.dateText
        liveBodies: root.liveBodies
        playbackOffsetMs: root.playbackOffsetMs
        offsetActive: root.offsetActive
        wrapFade: root.wrapFade
        playing: root.playing
        playPhase: root.playPhase
        playSegDays: root.playSegDays
        active: root.active
        onPlayToggleRequested: root.playToggleRequested()
        onSpeedStepRequested: (d) => root.speedStepRequested(d)
        onLiveRequested: root.liveRequested()
        focus: true
        onHoloToggleRequested: root.holoToggleRequested()   // holo flows down by binding only (Panel.qml owns it)
        onShowPlutoChanged: if (showPluto !== root.showPluto) root.showPluto = showPluto
        onRefreshRequested: {
            var before = root.lastManualRefresh
            root.refreshRequested()   // Panel.qml: manualRefresh() (60 s debounce) + view refresh
            var left = root.debounceMs - (Date.now() - root.lastManualRefresh)
            if (root.lastManualRefresh === before && before > 0 && left > 0) {
                root.refreshHint = "refresh in " + Math.ceil(left / 1000) + "s"
                hintTimer.restart()
            }
        }
        onSelectedIdChanged: root._mapSelection()
        Keys.forwardTo: [pager]   // v1.1: page keys first (pager accepts only 1 2 3 t, and j k Tab on pages 2/3)
    }
    function _mapSelection() {   // v1.0 behaviour, page 1 only (pages 2/3 rows are never selected)
        if (root.page !== 1) return
        for (var i = 0; i < scope.tableRows.length; i++) if (scope.tableRows[i].id === scope.selectedId) { table.currentIndex = i; table.positionViewAtIndex(i, ListView.Contain); return }
        table.currentIndex = -1
    }
    // v1.1 key target (Keys.forwardTo above: runs before the scope's own keys). Accepts only its keys; the rest falls through.
    Item {
        id: pager
        objectName: "pager"
        Keys.onPressed: function(e) {
            switch (e.key) {
            case Qt.Key_1: root.setPage(1); break
            case Qt.Key_2: root.setPage(2); break
            case Qt.Key_3: root.setPage(3); break
            case Qt.Key_T: root.showRoadster = !root.showRoadster; break
            case Qt.Key_Tab: case Qt.Key_J: if (root.page === 1) return; root.scrollRows(1); break
            case Qt.Key_Backtab: case Qt.Key_K: if (root.page === 1) return; root.scrollRows(-1); break
            default: return
            }
            e.accepted = true
        }
    }
    function setPage(n) {
        if (!(n === 1 || n === 2 || n === 3) || n === page) return
        page = n
        if (n !== 1) _syncExtra()
        table.positionViewAtBeginning()
        if (n === 1) { table.currentIndex = -1; _mapSelection() }
    }
    function scrollRows(d) {   // pages 2/3: j k move the visible window one row
        var max = Math.max(0, table.contentHeight - table.height)
        table.contentY = table.originY + Math.max(0, Math.min(max, table.contentY - table.originY + d * root.rowH))
    }

    // Error tooltip for the header (status.json lastError), elided if long.
    Rectangle {
        z: 10
        visible: srcHover.hovered && root.errorTip !== ""
        anchors { right: parent.right; top: header.bottom; rightMargin: root.pad; topMargin: 2 }
        width: Math.min(tipText.implicitWidth + 16, root.width - 2 * root.pad); height: tipText.implicitHeight + 10
        radius: 4; color: root.background; border.width: 1
        border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.3)
        Text {
            id: tipText; anchors.centerIn: parent; width: parent.width - 16
            text: root.errorTip; elide: Text.ElideRight; maximumLineCount: 1
            color: root.ink; opacity: 0.75; font { family: root.fontFamily; pixelSize: 11 }
        }
    }

    // Narrow panels: the selected body's readout as wrapped text under the scope (never over orbits).
    Text {
        id: detail
        anchors { left: parent.left; right: parent.right; bottom: sep.top; leftMargin: root.pad; rightMargin: root.pad; bottomMargin: 8 }
        visible: root.narrow
        readonly property var lines: { root.now; scope.tableRows; return root.narrow && scope.selectedId ? scope.readoutFor(scope.selectedId) : [] }
        readonly property string src: { for (var i = 0; i < root.bodies.length; i++) if (root.bodies[i].id === scope.selectedId) return root.bodies[i].source || ""; return "" }
        text: lines.length ? "<b>" + lines[0] + "</b>  " + lines.slice(1).map(function(l){ return l.replace(/\s+/g, " ").trim().replace(/ /g, "&nbsp;").replace(/\//g, "\u2060/\u2060") }).join(" \u00b7 ")
                             + (src ? " \u00b7 <font color='" + Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.5) + "'>src&nbsp;" + src + (root.staleBodies.indexOf(scope.selectedId) >= 0 ? " \u00b7 cached" : "") + "</font>" : "") : ""
        textFormat: Text.StyledText
        wrapMode: Text.WordWrap
        color: root.ink; opacity: 0.8
        font { family: root.fontFamily; pixelSize: 11 }
    }

    Rectangle {
        id: sep
        anchors { left: parent.left; right: parent.right; bottom: tableHead.top; leftMargin: root.pad; rightMargin: root.pad; bottomMargin: 8 }
        height: 1; color: root.ink; opacity: 0.15
    }

    // ---- table (fixed column widths, ListView; pattern from asteroid-radar Panel.qml:423-430, 967)
    readonly property real tableW: width - 2 * pad
    // Narrow: drop the light-time column so nothing collides and names are never elided.
    readonly property var colW: narrow ? [tableW * 0.28, tableW * 0.22, tableW * 0.26, tableW * 0.24, 0]
                                       : [tableW * 0.18, tableW * 0.20, tableW * 0.22, tableW * 0.20, tableW * 0.20]
    readonly property int rowH: narrow ? 21 : 25
    component Cell: Text {
        property int col: 0
        width: root.colW[col]
        horizontalAlignment: col === 0 ? Text.AlignLeft : Text.AlignRight
        font { family: root.fontFamily; pixelSize: 14; letterSpacing: 0.6 }   // Omarchy monospace (JetBrainsMono Nerd Font), airy
        color: root.ink
        visible: width > 0
    }
    Row {
        id: tableHead
        anchors { left: parent.left; right: parent.right; bottom: table.top; leftMargin: root.pad + 6; rightMargin: root.pad + 6; bottomMargin: 6 }
        Repeater {
            model: {
                var h = root.tableW >= 620 ? ["BODY", "DIST SUN (AU)", "DIST EARTH (AU)", "SPEED (km/s)", "LIGHT TIME"]
                                           : ["BODY", "SUN AU", "EARTH AU", "km/s", "LIGHT"]
                if (root.page === 2) { h[0] = "ASTEROID"; h[4] = root.tableW >= 620 ? "SIZE (km)" : "SIZE km" }
                else if (root.page === 3) h[0] = "BEYOND"
                return h
            }
            Cell { col: index; text: modelData; opacity: 0.8; font.pixelSize: 12; font.letterSpacing: 1; width: (root.tableW - 12) * root.colW[index] / root.tableW }
        }
    }
    ListView {
        id: table
        anchors { left: parent.left; right: parent.right; bottom: hint.top; leftMargin: root.pad; rightMargin: root.pad; bottomMargin: 12 }
        // v1.1 height lock: v1.0's height (scope rows only) on every page, so the scope above keeps its exact geometry.
        // Extra rows (Roadster, pages 2/3) scroll inside it.
        height: Math.min(scope.tableRows.length, 10) * root.rowH
        clip: true; interactive: contentHeight > height + 0.5; boundsBehavior: Flickable.StopAtBounds
        model: root.page === 1 ? rowsModel : extraModel
        currentIndex: -1
        highlightFollowsCurrentItem: false
        delegate: Item {
            id: row
            width: table.width; height: root.rowH
            readonly property bool sel: !model.extra && model.bid === scope.selectedId
            readonly property bool earth: model.bid === "earth"
            readonly property color c: earth ? root.earthInk : root.ink
            Rectangle { anchors.fill: parent; radius: 3; color: root.ink; opacity: row.sel ? 0.08 : 0 }
            Row {
                anchors { left: parent.left; right: parent.right; leftMargin: 6; rightMargin: 6; verticalCenter: parent.verticalCenter }
                readonly property real k: (root.tableW - 12) / root.tableW
                Cell { col: 0; color: row.c; width: root.colW[0] * parent.k; opacity: row.sel ? 1 : 0.75; font.bold: row.sel
                       text: model.extra && root.narrow ? model.sname : model.name
                       elide: model.extra && root.narrow ? Text.ElideRight : Text.ElideNone }
                Cell { col: 1; color: row.c; width: root.colW[1] * parent.k; text: root.fmtAU(model.dist, model.extra); opacity: row.sel ? 1 : 0.75 }
                Cell { col: 2; color: row.c; width: root.colW[2] * parent.k; opacity: row.sel ? 1 : 0.75
                       text: model.bid === "earth" ? "\u2013" : root.fmtAU(model.distEarth, model.extra) }
                Cell { col: 3; color: row.c; width: root.colW[3] * parent.k; text: isFinite(model.speed) ? model.speed.toFixed(2) : "\u2013"; opacity: row.sel ? 1 : 0.75 }
                Cell { col: 4; color: row.c; width: root.colW[4] * parent.k; opacity: row.sel ? 1 : 0.75
                       text: root.page === 2 ? (isFinite(model.size) ? String(Math.round(model.size)) : "\u2013") : scope.fmtLight(model.lightTime) }
            }
            MouseArea { anchors.fill: parent; onClicked: { if (!model.extra) scope.select(model.bid); scope.forceActiveFocus() } }   // extra rows: not selectable
        }
    }

    // Rows updated in place while the set of bodies is unchanged (1 Hz data must not reset the
    // view or currentIndex); rebuilt only when bodies are added/removed/reordered.
    ListModel { id: rowsModel }
    function _row(r) { return { bid: r.id, name: r.name, sname: r.name, extra: false, size: NaN, dist: r.info.dist, distEarth: r.info.distEarth, speed: r.info.speed, lightTime: r.info.lightTime } }
    function _xrow(x) { return { bid: x.id, name: x.name, sname: x.short || x.name, extra: true, size: x.size, dist: x.dist, distEarth: x.distEarth, speed: x.speed, lightTime: x.lightTime } }
    function _same(a, b) { return a === b || (typeof a === "number" && typeof b === "number" && isNaN(a) && isNaN(b)) }
    function _fill(model, list) {   // update in place while the ids are unchanged (no view reset); rebuild otherwise
        var same = list.length === model.count
        for (var i = 0; same && i < list.length; i++) if (model.get(i).bid !== list[i].bid) same = false
        if (same) {
            for (var j = 0; j < list.length; j++) { var o = list[j], m = model.get(j); for (var k in o) if (!_same(m[k], o[k])) model.setProperty(j, k, o[k]) }
            return false
        }
        model.clear()
        for (var n = 0; n < list.length; n++) model.append(list[n])
        return true
    }
    function _extra(id) { for (var i = 0; i < extraRows.length; i++) if (extraRows[i].id === id) return extraRows[i]; return null }
    function _syncRows() {
        var rows = scope.tableRows || [], list = rows.map(_row)
        var rs = showRoadster ? _extra("roadster") : null
        if (rs) list.push(_xrow(rs))   // after the scope rows: their indices (selection, scanline gap) stay v1.0's
        var hadRs = rowsModel.count > 0 && rowsModel.get(rowsModel.count - 1).bid === "roadster"
        if (_fill(rowsModel, list) && page === 1) {
            var sel = -1
            for (var q = 0; q < rows.length; q++) if (rows[q].id === scope.selectedId) sel = q
            table.currentIndex = sel
        }
        if (rs && !hadRs && page === 1) Qt.callLater(table.positionViewAtEnd)   // t on: bring the new row into view
    }
    // Pages 2/3: page 2 in catalog (size) order, page 3 sorted by distance from the Sun (missing distances last).
    ListModel { id: extraModel }
    function _syncExtra() {
        if (page === 1) return
        var l = extraRows.filter(function(x){ return x.page === root.page })
        if (page === 3) l = l.slice().sort(function(a, b){ var fa = isFinite(a.dist), fb = isFinite(b.dist); return fa && fb ? a.dist - b.dist : fa ? -1 : fb ? 1 : 0 })
        _fill(extraModel, l.map(_xrow))
    }
    onExtraRowsChanged: { _syncRows(); _syncExtra() }
    onShowRoadsterChanged: _syncRows()
    // Numbers: v1.0 format for scope rows; table-only rows get an en dash when missing and 2 decimals from 100 AU.
    function fmtAU(v, extra) { return !isFinite(v) ? "\u2013" : extra && v >= 100 ? v.toFixed(2) : v.toFixed(3) }
    function tableJson() {
        var m = page === 1 ? rowsModel : extraModel, rows = []
        function n(v) { return typeof v === "number" && isFinite(v) ? v : null }
        for (var i = 0; i < m.count; i++) { var r = m.get(i)
            rows.push({ id: r.bid, name: r.name, distSun: n(r.dist), distEarth: r.bid === "earth" ? null : n(r.distEarth), speed: n(r.speed),
                        lightTime: page === 2 ? undefined : n(r.lightTime), sizeKm: page === 2 ? n(r.size) : undefined }) }
        return JSON.stringify({ page: page, rows: rows })
    }
    Connections { target: scope; function onTableRowsChanged() { root._syncRows() } }
    Component.onCompleted: _syncRows()

    Timer { id: hintTimer; interval: 2000; repeat: false; onTriggered: root.refreshHint = "" }   // one-shot: runs only while shown

    // ---- hint line: full form when it fits on two lines, compact form otherwise
    TextMetrics { id: fullHint; font: hint.font; text: root.hintFull }
    // v1.1: new keys are listed only where they keep v1.0's line count; the hint's height is always v1.0's (hint10),
    // so the table and the scope above keep their exact v1.0 geometry.
    function _nb(a) { return a.map(function(t){ return t.replace(/ /g, "\u00a0") }).join(" \u00b7 ") }
    readonly property string hintFull11: _nb(["drag h l rotate", "\u2191 \u2193 tilt", "wheel + - zoom", "j k select", "space names", ". play", "[ ] speed", "p pluto", "t tesla", "1 2 3 page", "g holo", "0 live", "r refresh", "esc close"])
    readonly property string hintShort11: _nb(["hl \u2191 \u2193", "+ -", "jk", "spc names", ". play", "[ ]", "pgrt", "123", "0", "esc"])
    readonly property bool _v10full: fullHint.advanceWidth <= 1.8 * hint.width
    Text { id: hint10; visible: false; width: hint.width; font: hint.font; wrapMode: Text.WordWrap; lineHeight: 1.25; horizontalAlignment: Text.AlignHCenter
           text: root.refreshHint !== "" ? root.refreshHint : (root._v10full ? root.hintFull : root.hintShort) }
    Text { id: hint11; visible: false; width: hint.width; font: hint.font; wrapMode: Text.WordWrap; lineHeight: 1.25; horizontalAlignment: Text.AlignHCenter
           text: root._v10full ? root.hintFull11 : root.hintShort11 }
    readonly property string hintFull: ["drag h l rotate", "\u2191 \u2193 tilt", "wheel + - zoom", "j k select", "space names", ". play", "[ ] speed", "p pluto", "g holo", "0 live", "r refresh", "esc close"].map(function(t){ return t.replace(/ /g, "\u00a0") }).join(" \u00b7 ")   // a key never splits from its action
    readonly property string hintShort: ["hl \u2191 \u2193", "+ -", "jk", "spc names", ". play", "[ ]", "pgr", "0", "esc"].map(function(t){ return t.replace(/ /g, "\u00a0") }).join(" \u00b7 ")
    Text {
        id: hint
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 12 }
        width: parent.width - 2 * root.pad
        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideNone; wrapMode: Text.WordWrap   // every bound key listed; wraps to 2 lines
        height: hint10.implicitHeight   // v1.1 lock: v1.0's hint height
        text: root.refreshHint !== "" ? root.refreshHint
              : hint11.lineCount <= hint10.lineCount ? hint11.text : hint10.text
        color: root.ink; opacity: root.refreshHint !== "" ? 0.85 : 0.75
        font { family: root.fontFamily; pixelSize: 12; letterSpacing: 0.4 }
        lineHeight: 1.25
    }

    // ---- holo texture: 1px horizontal scanlines every 3px at 5% opacity. Painted once per size
    // (and on tint change); never animated, no shader. Pure overlay: affects no geometry.
    Canvas {
        id: scanlines
        objectName: "scanlines"
        anchors.fill: parent
        z: 100
        visible: root.holo
        enabled: false   // never takes input
        renderStrategy: Canvas.Cooperative
        onWidthChanged: requestPaint(); onHeightChanged: requestPaint(); onVisibleChanged: if (visible) requestPaint()
        onPainted: _key = JSON.stringify(holes()) + root.width + "x" + root.height
        Connections { target: root; function onInkChanged() { scanlines.requestPaint() } function onHoloChanged() { scanlines.requestPaint() } }
        // Repaint only when a hole actually moves: the card, or the selected body's row
        // (index in tableRows * rowH - contentY). 1 Hz data updates leave the key unchanged.
        property string _key: ""
        function _check() { var k = JSON.stringify(holes()) + root.width + "x" + root.height; if (k !== _key) { _key = k; requestPaint() } }
        Connections { target: scope; function onCardRectChanged() { scanlines._check() } function onSelectedIdChanged() { scanlines._check() } function onTableRowsChanged() { scanlines._check() } }
        Connections { target: root; function onPageChanged() { scanlines._check() } }
        Connections { target: table; function onContentYChanged() { scanlines._check() } function onYChanged() { scanlines._check() } function onHeightChanged() { scanlines._check() } }
        // Areas that already carry their single fill (G17: <= 8%) get no scanlines on top.
        function holes() {
            var r = [], cr = scope.cardRect
            if (cr && cr.length === 4) { var p = scope.mapToItem(scanlines, cr[0], cr[1]); r.push([Math.round(p.x), Math.round(p.y), cr[2], cr[3]]) }
            var rows = root.page === 1 ? (scope.tableRows || []) : [], idx = -1   // v1.1: selected-row gap on page 1 only
            for (var i = 0; i < rows.length; i++) if (rows[i].id === scope.selectedId) { idx = i; break }
            if (idx >= 0) {
                var top = idx * root.rowH - table.contentY + table.originY
                if (top + root.rowH > 0 && top < table.height) {
                    var y0 = Math.max(0, top), y1 = Math.min(table.height, top + root.rowH)
                    var q = table.mapToItem(scanlines, 0, y0); r.push([Math.round(q.x), Math.round(q.y), table.width, y1 - y0])
                }
            }
            return r
        }
        onPaint: {
            var c = getContext("2d"); c.reset()
            if (!root.holo) return
            c.fillStyle = root.ink; c.globalAlpha = 0.05
            var hs = holes()
            for (var y = 1; y < height; y += 3) {
                // split each line around the holes on this row (no clip path: explicit segments)
                var cuts = hs.filter(function(h){ return y >= h[1] && y < h[1] + h[3] }).sort(function(a, b){ return a[0] - b[0] })
                var x0 = 0
                cuts.forEach(function(h){ if (h[0] > x0) c.fillRect(x0, y, h[0] - x0, 1); x0 = Math.max(x0, h[0] + h[2]) })
                if (x0 < width) c.fillRect(x0, y, width - x0, 1)
            }
        }
    }
}
