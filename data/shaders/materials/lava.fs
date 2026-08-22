// Lava.
//
// Molten rock reads as molten rock because of one thing: a skin of
// cooled crust floats on a white-orange melt, and the skin is cracked.
// The plates do not glow, the cracks do. So this shader builds a plate
// map first — a cellular pattern that drifts very slowly, so the seams
// between plates open and close over several seconds — and uses the
// distance to the nearest seam to decide, cell by cell, whether the
// surface is dark cooled rock or a line of raw melt showing through.
//
// The melt itself runs through the blackbody order as it is judged
// deeper or shallower: white at the core, through yellow and orange to
// a dying red at the coolest edge. `s.top` pushes the skin thicker on a
// face that looks straight up, the way a pool crusts hardest where it
// meets open air, and `s.depth` pushes the glow of the body hotter the
// further under that skin a cell sits. The emissive light is added
// after `m_dress`, because lava is a light source, not a lit thing —
// only the cooled crust itself is dressed, the way stone would be.

#define M_ROLL 1.1

const vec3 LAVA_WHITE  = vec3(1.000, 0.960, 0.850);
const vec3 LAVA_YELLOW = vec3(1.000, 0.780, 0.220);
const vec3 LAVA_ORANGE = vec3(0.980, 0.420, 0.070);
const vec3 LAVA_RED    = vec3(0.520, 0.060, 0.020);
const vec3 LAVA_DEADRED= vec3(0.180, 0.020, 0.012);

const vec3 LAVA_CRUST_LIT  = vec3(0.145, 0.128, 0.118); // cooled rock, lit
const vec3 LAVA_CRUST_HOT  = vec3(0.310, 0.140, 0.070); // crust near a crack, baked

const float LAVA_PLATE_SCALE = 0.115;   // size of a crust plate, cells
const float LAVA_DRIFT_SPEED = 0.028;   // how fast plates creep apart
const float LAVA_CRACK_WIDTH = 0.10;    // how wide the glow shows at a seam
const float LAVA_SHIMMER_AMT = 0.10;

// The plates drift as one slow, wandering offset shared by the whole
// pool, so neighbouring plates keep their edges lined up while the
// gaps between them breathe open and shut.
vec2 lava_drift(vec2 c)
{
    float t = seconds*LAVA_DRIFT_SPEED;
    return vec2(m_fbm(c*0.02 + vec2(t, -t*0.7), 2) - 0.5,
                m_fbm(c*0.02 + vec2(-t*0.6, t*0.9) + 11.0, 2) - 0.5)*3.2;
}

// Distance to the nearest plate seam, 0 at the seam and rising toward
// the middle of a plate.
float lava_seam(vec2 c, out vec2 hit)
{
    vec2 p = c*LAVA_PLATE_SCALE + lava_drift(c)*LAVA_PLATE_SCALE;
    vec3 f = m_cells(p);
    hit = f.yz;
    return f.x;
}

// The blackbody ramp: white at the hottest, through yellow, orange and
// a deep dying red at the coolest. `h` is heat, 0 to 1.
vec3 lava_blackbody(float h)
{
    h = clamp(h, 0.0, 1.0);
    vec3 col = LAVA_DEADRED;
    col = mix(col, LAVA_RED, smoothstep(0.0, 0.30, h));
    col = mix(col, LAVA_ORANGE, smoothstep(0.25, 0.58, h));
    col = mix(col, LAVA_YELLOW, smoothstep(0.55, 0.82, h));
    col = mix(col, LAVA_WHITE, smoothstep(0.80, 1.0, h));
    return col;
}

vec3 shade(Surf s)
{
    // A slow shimmer on the melt only: the air over lava bends light.
    vec2 shimmer = vec2(m_noise(s.cell*0.35 + seconds*0.6),
                         m_noise(s.cell*0.35 - seconds*0.5 + 8.0))*LAVA_SHIMMER_AMT;

    vec2 hit;
    float seam = lava_seam(s.cell + shimmer, hit);

    // A pool crusts hardest where it faces straight up into open air,
    // and hardly at all where a cell is buried deep under other lava —
    // that is still-molten body, not surface. Depth pushes the crack
    // shut as the cell sits deeper in the flow.
    float crustiness = clamp(s.top*0.85 + 0.15, 0.0, 1.0)*clamp(1.0 - s.depth*0.10, 0.35, 1.0);
    float crackWidth = LAVA_CRACK_WIDTH*mix(1.5, 0.55, crustiness);
    float crack = 1.0 - smoothstep(0.0, crackWidth, seam);

    // ---- the crust: cooled black-grey rock, cracked, lightly relieved.
    float grain = m_fbm(s.cell*0.9 + hit*0.7, 3);
    vec3 rock = mix(LAVA_CRUST_LIT*0.7, LAVA_CRUST_LIT*1.25, grain);
    // A baked halo just outside a crack, where the rock itself is hot.
    float bake = (1.0 - crack)*(1.0 - smoothstep(0.0, crackWidth*2.2, seam));
    rock = mix(rock, LAVA_CRUST_HOT, bake*0.55);

    vec3 crustLit = m_dress(rock, s);

    // ---- the melt: the blackbody body, glowing through the cracks and
    // through any spot the crust has not closed over.
    float open = max(crack, 1.0 - crustiness);

    // Heat runs hotter with depth (the body under the skin) and hotter
    // right at the rim where melt touches cold rock and the temperature
    // gradient is steepest — the brightest line in the whole pool.
    float bodyHeat = clamp(0.32 + s.depth*0.10, 0.0, 1.0);
    float rimHeat = s.edge*(1.0 - s.bury)*0.55;
    float crackHeat = smoothstep(crackWidth, 0.0, seam);
    float heat = clamp(bodyHeat + crackHeat*0.55 + rimHeat, 0.0, 1.15);

    // A slow inner flicker, so the melt is never perfectly steady.
    heat += (m_noise(s.cell*0.6 + seconds*1.3) - 0.5)*0.10*crackHeat;

    vec3 melt = lava_blackbody(heat);

    // The hottest cracks blow out toward white — lava is the brightest
    // thing in the world after the wizard's orb.
    melt += LAVA_WHITE*pow(crackHeat, 6.0)*0.6;

    // A thin dark fume sits just above an open melt surface, cheaply:
    // darken cells that read as open melt but sit high (low depth, high
    // top), thinning the glow rather than costing another pass.
    float fume = s.top*(1.0 - clamp(s.depth*0.5, 0.0, 1.0))*0.12*open;
    melt *= (1.0 - fume);

    vec3 emissive = melt*open;

    return crustLit + emissive;
}
