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
const vec3 EMBER_ASH   = vec3(0.300, 0.290, 0.280); // pale ash, only on faces turned up
const vec3 EMBER_SHEEN = vec3(0.340, 0.300, 0.280); // what little glassy sheen the crust has left

const float EMBER_FACET = 0.20;  // the same facet size as cold coal
const float EMBER_TILT  = 1.10;
const float EMBER_SHEEN_GLOSS = 20.0;
const float EMBER_SHEEN_STR   = 0.09; // dim: a dying crust, not a glassy one

const float EMBER_ASH_SCALE = 0.16; // the ash gathers in patches, not a wash
const float EMBER_ASH_LO = 0.36;
const float EMBER_ASH_HI = 0.78;
const float EMBER_ASH_STR = 0.55;

const vec3 EMBER_RED    = vec3(0.860, 0.095, 0.020); // the coolest a crack still shows
const vec3 EMBER_ORANGE = vec3(1.000, 0.460, 0.050);
const vec3 EMBER_WHITE  = vec3(1.000, 0.920, 0.720); // the hottest, thinnest crust
const float EMBER_HEAT_STR = 2.05;
const float EMBER_THIN_MIN = 0.32; // a buried crack still glows, just banked down

// One family of cracks, exactly as `coal_cleat`: parallel, walked off a
// straight line, and gated so a crack fades and picks up again along its
// own length. `id` comes back naming which stretch of the crack this
// pixel falls in, so every stretch can flare on its own clock.
float ember_crack(vec2 c, float angle, float spacing, float width,
                   float jitter, float broken, float seed, float segment,
                   out float id)
{
    vec2 dir = vec2(cos(angle), sin(angle));
    vec2 perp = vec2(-dir.y, dir.x);
    float along = dot(c, dir);
    float across = dot(c, perp);

    float wobble = (m_noise(vec2(along*0.22, seed)) - 0.5)*jitter;
    float g = abs(fract((across + wobble)/spacing + 0.5) - 0.5)*spacing;
    float line = 1.0 - smoothstep(width*0.35, width, g);

    float gate = smoothstep(0.5 - broken*0.5, 0.5 + broken*0.5,
                             m_fbm(vec2(along, across)*0.09 + seed*7.0, 2));

    id = floor(along/segment) + seed*97.0;
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
    float id1, id2b;
    float c1 = ember_crack(s.cell, angle1, 11.0, 0.40, 0.9, 0.35, 1.3, 3.5, id1);
    float c2 = ember_crack(s.cell, angle1 + 1.55, 7.5, 0.28, 0.6, 0.78, 5.7, 2.6, id2b)*0.75;

    // A crack glows less the deeper it is buried under sound crust, but
    // even deep inside a lump it never quite goes out.
    float thin = mix(EMBER_THIN_MIN, 1.0, s.edge*0.6 + s.ao*0.4);

    float heat1 = c1*ember_flicker(id1, 11.0)*thin;
    float heat2 = c2*ember_flicker(id2b, 47.0)*thin;

    vec3 glow = ember_heat_color(heat1)*heat1 + ember_heat_color(heat2)*heat2*0.9;

    // Added after `m_dress`, so the fire is the material's own light and
    // keeps burning even where nothing else in the cave is lit at all.
    return dressed + glow*EMBER_HEAT_STR;
}
