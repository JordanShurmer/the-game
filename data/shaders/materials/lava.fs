// Lava.
//
// Molten rock reads as molten rock because of one thing: a skin of
// cooled crust floats on a white-orange melt, and the skin is cracked.
// The plates do not glow, the cracks do. So this shader builds a plate
// map — a cellular pattern that drifts very slowly, so the seams
// between plates open and close over several seconds — and uses the
// distance to the nearest seam to decide, cell by cell, how much of
// the cooled crust has closed over the melt beneath it.
//
// The crust covers most of a body: `s.bury` says how deep inside the
// pool a cell sits, and a cell buried well inside has had room to grow
// a full plate, so its cracks run thin. A cell on the rim of a small
// drop has had no such room, so more of it stays open melt. `s.depth`
// pushes the melt hotter the further under the surface a crack reaches,
// and the true edge of the body — where melt meets cold rock — carries
// its own thin, brighter line, because that is where the temperature
// falls fastest of all.
//
// The melt itself runs the blackbody order: white at its hottest, down
// through yellow, orange and a dying red at the coolest. Only the crust
// is sunk into the dark by `m_dress`; the melt is mixed in after, at
// full strength, because lava lights itself.

#define M_ROLL 1.1

const vec3 LAVA_WHITE   = vec3(1.000, 0.960, 0.850);
const vec3 LAVA_YELLOW  = vec3(1.000, 0.760, 0.200);
const vec3 LAVA_ORANGE  = vec3(0.960, 0.380, 0.060);
const vec3 LAVA_RED     = vec3(0.480, 0.050, 0.020);
const vec3 LAVA_DEADRED = vec3(0.140, 0.014, 0.010);

const vec3 LAVA_CRUST_DARK = vec3(0.050, 0.044, 0.042); // cooled rock, plate middle
const vec3 LAVA_CRUST_LIT  = vec3(0.150, 0.128, 0.112); // cooled rock, grain catches light
const vec3 LAVA_CRUST_BAKE = vec3(0.360, 0.150, 0.075); // rock baked just outside a crack

const float LAVA_PLATE_SCALE = 0.082;  // size of a crust plate, in cells
const float LAVA_DRIFT_SPEED = 0.100;  // how fast the plate seams creep
const float LAVA_DRIFT_RANGE = 2.2;    // cells a seam wanders across
const float LAVA_CRACK_BASE  = 0.060;  // half-width of the hottest core
const float LAVA_CRACK_GLOW  = 1.9;    // how much further the colour is seen
const float LAVA_SHIMMER_AMT = 0.09;
const float LAVA_RELIEF      = 0.85;   // how hard the plates themselves bevel

// The plates drift as one slow, wandering field shared by the whole
// pool, so neighbouring plates keep their edges lined up while the
// gaps between them breathe open and shut.
vec2 lava_drift(vec2 c)
{
    float t = seconds*LAVA_DRIFT_SPEED;
    return vec2(m_fbm(c*0.015 + vec2(t, -t*0.7), 2) - 0.5,
                m_fbm(c*0.015 + vec2(-t*0.6, t*0.9) + 11.0, 2) - 0.5)*LAVA_DRIFT_RANGE;
}

// `m_cells` gives the distance to the nearest of a scatter of points,
// which draws dots. A crust is plates, so what is wanted is the seam
// *between* two points: the gap between the closest point and the
// second closest, which is near zero right on the border of a plate
// and widens toward the middle of one. That is what carries the crack.
void lava_voronoi(vec2 p, out float edge, out vec2 cell)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    float best1 = 8.0;
    float best2 = 8.0;
    cell = vec2(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec2 c = m_hash2(i + o);
            float len = length(o + c - f);
            if (len < best1) { best2 = best1; best1 = len; cell = i + o; }
            else if (len < best2) { best2 = len; }
        }
    }
    edge = best2 - best1;
}

// The blackbody ramp: a dying red, through orange and yellow, to a
// white core. `h` is heat, 0 to 1.
vec3 lava_blackbody(float h)
{
    h = clamp(h, 0.0, 1.0);
    vec3 col = LAVA_DEADRED;
    col = mix(col, LAVA_RED, smoothstep(0.0, 0.28, h));
    col = mix(col, LAVA_ORANGE, smoothstep(0.22, 0.55, h));
    col = mix(col, LAVA_YELLOW, smoothstep(0.50, 0.80, h));
    col = mix(col, LAVA_WHITE, smoothstep(0.78, 1.0, h));
    return col;
}

vec3 shade(Surf s)
{
    // A slow shimmer, so the crack pattern itself trembles a little —
    // the look of heat bending the air right at the melt.
    vec2 shimmer = vec2(m_noise(s.cell*0.4 + seconds*0.55),
                         m_noise(s.cell*0.4 - seconds*0.47 + 8.0) - 0.5)*LAVA_SHIMMER_AMT;

    vec2 p = (s.cell + shimmer)*LAVA_PLATE_SCALE + lava_drift(s.cell)*LAVA_PLATE_SCALE;
    float seam;
    vec2 hit;
    lava_voronoi(p, seam, hit);

    // A plate buried well inside a body has had room to grow thick and
    // close its cracks to hairlines; a cell on the rim of a small drop
    // has not, and stays mostly open melt.
    float maturity = clamp(s.bury*1.05 + 0.10, 0.10, 1.20);
    float hotHalf = LAVA_CRACK_BASE/maturity;
    float visHalf = hotHalf*LAVA_CRACK_GLOW;

    // Two widths from the same seam: `blend` says how much melt shows
    // at all, and reaches out past the hot core so the crack can be
    // seen cooling to red before it gives way to rock. `heatT` is the
    // narrower one, 1 dead in the seam and 0 already at the edge of
    // the hot core, which is what makes the centre run white-yellow
    // while the flanks run orange and red.
    float blend = smoothstep(visHalf, 0.0, seam);
    float heatT = clamp(1.0 - seam/hotHalf, 0.0, 1.0);
    heatT = pow(heatT, 1.3);

    // Different fissures run at different temperatures, and none of
    // them sit still.
    float crackTemp = mix(0.45, 1.0, m_hash(hit));
    float depthBump = clamp(s.depth*0.018, 0.0, 0.25);
    float flicker = (m_noise(s.cell*0.7 + seconds*1.1 + hit) - 0.5)*0.10;

    // Even where the hot core has faded to nothing, a visible crack
    // still carries a dim, dying red — that is the cooling tail.
    float heat = clamp(mix(0.10, 1.0, heatT)*crackTemp + depthBump*heatT + flicker*heatT, 0.0, 1.15);
    vec3 melt = lava_blackbody(heat);
    // The very hottest cracks blow toward white — lava is the
    // brightest thing in the world after the wizard's orb.
    melt += LAVA_WHITE*pow(max(heat - 0.90, 0.0)*10.0, 2.0)*0.7;

    // ---- the crust: dark cooled rock, relieved into facets so light
    // rakes across the plates the way it does a broken rock face, and
    // baked paler in a halo just outside a crack.
    float grain = m_fbm(s.cell*0.85 + hit*0.6, 3);
    vec3 plateNormal = normalize(s.n + vec3((grain - 0.5)*LAVA_RELIEF,
                                             (m_hash(hit) - 0.5)*LAVA_RELIEF*0.6, 0.0));
    float relief = clamp(dot(plateNormal, s.l)*0.5 + 0.5, 0.0, 1.0);

    float fine = m_noise(s.cell*2.6 + hit*1.3); // the broken texture of cooled rock
    vec3 rock = mix(LAVA_CRUST_DARK, LAVA_CRUST_LIT, grain);
    rock *= mix(0.65, 1.05, m_hash(hit + 4.1)); // each plate its own shade
    rock *= mix(0.55, 1.40, relief);            // the bevel of the plate itself
    rock *= mix(0.82, 1.12, fine);              // the broken grain within it
    float halo = 1.0 - smoothstep(hotHalf, visHalf*1.4, seam);
    rock = mix(rock, LAVA_CRUST_BAKE, halo*(1.0 - blend)*0.6);

    vec3 col = mix(m_dress(rock, s), melt, blend);

    // The true edge of the body, where melt meets cold rock, is the
    // steepest temperature drop there is, and the brightest line of
    // all. It shows as a thin band partway through the bevel, not a
    // flat wash across the whole rim.
    float rim = 4.0*s.edge*(1.0 - s.edge);
    col += mix(LAVA_ORANGE, LAVA_WHITE, 0.6)*rim*rim*0.55;

    // A thin dark fume sits just over open melt facing the open air.
    float fume = s.top*blend*0.10;
    col *= (1.0 - fume);

    return col;
}
