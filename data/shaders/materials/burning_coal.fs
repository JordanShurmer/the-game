// Burning_Coal.
//
// The same seam as `coal.fs`, alight: the same facets, cut by the same
// two families of cleats, but now the crust between the cracks has gone
// cold and dead — properly black, a hair of ash bloomed across whatever
// faces up — while the cracks themselves are no longer cracks at all.
// They are the fire, seen through the rock: a hot network of orange and
// white showing wherever the crust between the coal has burned thin,
// which is brightest at a rim or a lone ember and dimmer, but never
// dark, deep inside a buried lump. Nothing here answers the world's
// light — the glow is the material's own, added after `m_dress` so it
// keeps burning in a cave with nothing else lit at all.
//
// It breathes: every stretch of crack carries its own hashed phase and
// rate, well under a hertz and run through value noise instead of a
// sine, so the flare never reads as one lamp pulsing — it reads as a
// bed of embers, each catching a moment after its neighbour.

// The same hard, glassy roll as cold coal: it is the same rock.
#define M_ROLL 2.1

const vec3 EMBER_BLACK = vec3(0.022, 0.015, 0.013); // the dead crust between the cracks
const vec3 EMBER_ASH   = vec3(0.460, 0.440, 0.420); // pale ash, only on faces turned up
const vec3 EMBER_SHEEN = vec3(0.340, 0.300, 0.280); // what little glassy sheen the crust has left

const float EMBER_FACET = 0.20;  // the same facet size as cold coal
const float EMBER_TILT  = 1.10;
const float EMBER_SHEEN_GLOSS = 20.0;
const float EMBER_SHEEN_STR   = 0.09; // dim: a dying crust, not a glassy one

const float EMBER_ASH_SCALE = 0.16; // the ash gathers in patches, not a wash
const float EMBER_ASH_LO = 0.30;
const float EMBER_ASH_HI = 0.62;
const float EMBER_ASH_STR = 0.90;

const vec3 EMBER_RED    = vec3(0.860, 0.095, 0.020); // the coolest a crack still shows
const vec3 EMBER_ORANGE = vec3(1.000, 0.460, 0.050);
const vec3 EMBER_WHITE  = vec3(1.000, 0.920, 0.720); // the hottest, thinnest crust
const float EMBER_HEAT_STR = 2.05;
const float EMBER_THIN_MIN = 0.32; // a buried crack still glows, just banked down

// How far the plane is bent before a crack is measured, and how coarse
// the bend is. This is what stops the two families reading as a lattice.
const float EMBER_WARP = 26.0;
const float EMBER_WARP_SCALE = 0.028;

// How far past the crack the heat bleeds into the crust, as a multiple
// of the crack's own width.
const float EMBER_HALO_W = 7.0;
const float EMBER_HALO_STR = 0.30;

// A lump does not burn evenly. Some of it is dead crust and some of it
// is blazing, in patches tens of cells across. Without this the cracks
// cover the whole face at one strength and read as a net thrown over the
// coal rather than as a coal that is alight.
const float EMBER_REGION_SCALE = 0.020;
const float EMBER_REGION_LO = 0.30;
const float EMBER_REGION_HI = 0.74;
const float EMBER_REGION_DEAD = 0.05;

// One family of cracks.
//
// A straight family of parallel lines reads as a wireframe laid over the
// coal, not as a coal that has split. Three things break it up. The
// whole plane is warped by a slow noise before the line is measured, so
// the family bends and the lines converge and part the way real cleats
// do. The line then wobbles again along its own length. Last, a gate
// breaks each line into stretches, so a crack runs, dies out, and picks
// up again a few cells on.
//
// `id` comes back naming which stretch this pixel falls in, so every
// stretch can flare on its own clock. `halo` comes back as the heat
// bleeding into the crust either side of the crack, which is what stops
// the glow reading as a drawn line.
float ember_crack(vec2 c, float angle, float spacing, float width,
                   float jitter, float broken, float seed, float segment,
                   out float id, out float halo)
{
    // Bend the whole family. This is the change that turns a lattice
    // into a split.
    vec2 warp = c + vec2(
        m_fbm(c*EMBER_WARP_SCALE + seed, 3) - 0.5,
        m_fbm(c*EMBER_WARP_SCALE + seed + 31.7, 3) - 0.5)*EMBER_WARP;

    vec2 dir = vec2(cos(angle), sin(angle));
    vec2 perp = vec2(-dir.y, dir.x);
    float along = dot(warp, dir);
    float across = dot(warp, perp);

    float wobble = (m_fbm(vec2(along*0.09, seed), 3) - 0.5)*jitter*spacing;
    float g = abs(fract((across + wobble)/spacing + 0.5) - 0.5)*spacing;

    float line = 1.0 - smoothstep(width*0.35, width, g);
    halo = 1.0 - smoothstep(width, width*EMBER_HALO_W, g);

    // Break the line into stretches along its length.
    float gate = smoothstep(0.5 - broken*0.5, 0.5 + broken*0.5,
                             m_fbm(vec2(along*0.16, across*0.05) + seed*7.0, 3));

    id = floor(along/segment) + seed*97.0;
    halo *= gate;
    return line*gate;
}

// A slow, uneven breath for one stretch of crack: its own hashed rate,
// under a hertz, run through value noise instead of a sine so it never
// settles into a visible period.
float ember_flicker(float id, float seed)
{
    float r = m_hash(vec2(id, seed));
    float rate = mix(0.12, 0.46, r);
    float phase = r*41.0 + seed*13.0;
    float n = m_noise(vec2(seconds*rate + phase, id*0.31 + seed));
    return mix(0.35, 1.15, n);
}

// The colour of a crack at a given heat: banked red, through orange, up
// to a white-hot core where the crust has burned thinnest.
vec3 ember_heat_color(float heat)
{
    vec3 c = mix(EMBER_RED, EMBER_ORANGE, smoothstep(0.0, 0.55, heat));
    return mix(c, EMBER_WHITE, smoothstep(0.55, 1.25, heat));
}

vec3 shade(Surf s)
{
    // The same faceted crust as cold coal, just banked: a constant tilt
    // per plate so what little sheen is left still jumps plate to plate.
    vec3 f = m_cells(s.cell*EMBER_FACET);
    vec2 id2 = f.yz;
    vec2 tilt = (m_hash2(id2) - 0.5)*EMBER_TILT;
    s.n = normalize(vec3(s.n.xy + tilt, s.n.z));

    // Ash gathers in patches on whatever faces the open air above it,
    // never on a wall or the underside of a lump.
    float ash_noise = m_fbm(s.cell*EMBER_ASH_SCALE, 3);
    float ash = s.top*smoothstep(EMBER_ASH_LO, EMBER_ASH_HI, ash_noise)*EMBER_ASH_STR;
    vec3 crust = mix(EMBER_BLACK, EMBER_ASH, ash);

    // A thin, mostly dead diffuse return — this crust drinks the light
    // as thoroughly as cold coal did.
    float ndl = m_diffuse(s);
    vec3 lit = crust*(ndl*0.35 + 0.65)*mix(0.55, 1.0, s.ao);

    // The last of the glassy sheen, much dimmer than in cold coal: a
    // crust this hot has mostly gone dead matte.
    vec3 h = normalize(s.l + M_VIEW);
    float ndh = max(dot(s.n, h), 0.0);
    lit += EMBER_SHEEN*pow(ndh, EMBER_SHEEN_GLOSS)*EMBER_SHEEN_STR;

    vec3 dressed = m_dress(lit, s);

    // The two cleat families, exactly as in cold coal, but read now as
    // the fire glowing up through the crust rather than a dark seam.
    float angle1 = 0.40;
    float id1, id2b, halo1, halo2;
    float c1 = ember_crack(s.cell, angle1, 18.0, 0.55, 0.30, 0.94, 1.3, 3.5, id1, halo1);
    float c2 = ember_crack(s.cell, angle1 + 1.55, 13.0, 0.38, 0.42, 0.97, 5.7, 2.6, id2b, halo2);
    c2 *= 0.75;
    halo2 *= 0.75;

    // A crack glows less the deeper it is buried under sound crust, but
    // even deep inside a lump it never quite goes out.
    float thin = mix(EMBER_THIN_MIN, 1.0, s.edge*0.6 + s.ao*0.4);

    // Where this part of the lump has caught at all.
    float region = smoothstep(EMBER_REGION_LO, EMBER_REGION_HI,
                              m_fbm(s.cell*EMBER_REGION_SCALE, 4));
    thin *= mix(EMBER_REGION_DEAD, 1.0, region);

    float heat1 = c1*ember_flicker(id1, 11.0)*thin;
    float heat2 = c2*ember_flicker(id2b, 47.0)*thin;

    // The crust either side of a crack is hot too, and it is that bleed,
    // not the crack itself, that says the whole lump is alight.
    float bleed = (halo1*ember_flicker(id1, 11.0) + halo2*ember_flicker(id2b, 47.0))*thin;

    vec3 glow = ember_heat_color(heat1)*heat1 + ember_heat_color(heat2)*heat2*0.9;
    glow += ember_heat_color(bleed*0.45)*bleed*EMBER_HALO_STR;

    // Added after `m_dress`, so the fire is the material's own light and
    // keeps burning even where nothing else in the cave is lit at all.
    return dressed + glow*EMBER_HEAT_STR;
}
