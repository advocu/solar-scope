// Maps Orbits.js output -> SolarScopeView `bodies` entries. Per-body errors (LookupError
// or anything else) hide that body; one bad body never breaks the frame.
.pragma library

// cache: plain object kept by the caller; holds slow-changing orbit/trail polylines.
// opts: {frame, trailDays, trailPoints, trailEverySec, orbitPoints}
function build(Orbits, jd, cache, opts) {
    opts = opts || {}
    var frame = opts.frame || "heliocentric"
    var list = [], entries
    try { entries = Orbits.bodies() } catch (e) { console.warn("solarscope: Orbits.bodies() failed:", e); return [] }
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        try {
            var s = Orbits.state(e.id, jd, frame)
            if (!s || !s.pos || s.pos.length < 3 || !isFinite(s.pos[0])) continue
            var c = cache[e.id] || (cache[e.id] = {})
            if (c.orbit === undefined) {
                try { c.orbit = typeof Orbits.orbit === "function" && e.parent === "sun" ? Orbits.orbit(e.id, jd, opts.orbitPoints || 180) : [] }
                catch (oe) { c.orbit = [] }
            }
            if (e.id !== "sun" && (c.trailJd === undefined || Math.abs(jd - c.trailJd) * 86400 >= (opts.trailEverySec || 60))) {
                try { c.trail = Orbits.trail(e.id, jd, opts.trailDays || 30, opts.trailPoints || 24, frame); c.trailJd = jd }
                catch (te) { c.trail = []; c.trailJd = jd }
            }
            list.push({ id: e.id, name: e.name, type: e.type, parent: e.parent, radius_km: e.radius_km,
                        default_visible: e.default_visible, stats: e.stats, source: s.source,
                        pos: s.pos, vel: s.vel || [0, 0, 0],
                        distance_km: s.distance_km, speed_km_s: s.speed_km_s, light_time_s: s.light_time_s,
                        orbit: c.orbit && c.orbit.length > 2 ? c.orbit : undefined,
                        trail: c.trail && c.trail.length ? c.trail : undefined })
        } catch (err) {
            // LookupError (no cache, no elements) or any other failure: hide this body.
            if (!err || err.name !== "LookupError") console.warn("solarscope: hiding", e && e.id, err)
        }
    }
    return list
}
