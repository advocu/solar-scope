// Table-only bodies (pages 2 and 3, and the Roadster row on page 1). Never drawn in the scope: these bodies live in
// their own Orbits.create() ephemeris fed by <cache>/extras.json, so the scope's bodies (Orbits.js singleton) never change.
// Pure ES5, no I/O, no timers. Missing data -> NaN (the table shows an en dash).
.pragma library

var AU_KM = 149597870.7;
var LIGHT_S_PER_AU = 499.004784;

function _len(v) { return Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }

// One table row from a heliocentric state (pos AU, vel AU/day) and Earth's heliocentric position (or null).
function row(id, name, shortName, page, sizeKm, pos, vel, earthPos) {
    var r = { id: id, name: name, short: shortName || name, page: page, size: (typeof sizeKm === "number" && isFinite(sizeKm)) ? sizeKm : NaN,
              dist: NaN, distEarth: NaN, speed: NaN, lightTime: NaN };
    if (!pos || pos.length < 3 || !isFinite(pos[0])) return r;
    r.dist = _len(pos);
    r.lightTime = r.dist * LIGHT_S_PER_AU;
    if (vel && vel.length >= 3 && isFinite(vel[0])) r.speed = _len(vel) * AU_KM / 86400;
    if (earthPos && earthPos.length >= 3 && isFinite(earthPos[0])) r.distEarth = _len([pos[0] - earthPos[0], pos[1] - earthPos[1], pos[2] - earthPos[2]]);
    return r;
}

// eph: Orbits.create(catalog) (or null), catalog: [{id,name,short,page,diameter_km}], jd: JD TDB,
// live: Panel liveBodies (Adapter.build output). Returns rows for every catalog body plus Pluto (page 3, from `live`).
function build(eph, catalog, jd, live) {
    var out = [], earth = null, pluto = null, i;
    for (i = 0; i < (live || []).length; i++) {
        if (live[i].id === "earth") earth = live[i].pos;
        else if (live[i].id === "pluto") pluto = live[i];
    }
    if (pluto) out.push(row("pluto", pluto.name || "Pluto", pluto.name || "Pluto", 3, NaN, pluto.pos, pluto.vel, earth));
    for (i = 0; i < (catalog || []).length; i++) {
        var b = catalog[i], s = null;
        if (eph) { try { s = eph.tryState(b.id, jd, "heliocentric"); } catch (e) { s = null; } }
        out.push(row(b.id, b.name, b.short, b.page, b.diameter_km, s ? s.pos : null, s ? s.vel : null, earth));
    }
    return out;
}
