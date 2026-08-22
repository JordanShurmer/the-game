// Coal.
//
// Bituminous coal breaks with a vitreous, almost glassy fracture: flat
// conchoidal faces a few cells across, each holding its own tilt, so a
// lump is not one rolled boulder but a jumble of little mirrors. Most of
// those faces are dead matte — dull, sooty, drinking the light whole —
// and only a few catch a hard, narrow, slightly cool highlight. That
// contrast, glass against soot, is almost the entire material: the body
// itself barely lifts off black.
//
// Two more things carry the read:
//
//  - cleats. Coal splits along two families of near-perpendicular
//    cracks, fixed in the rock, not in the noise field: a strong,
//    fairly continuous face cleat and a fainter, choppier butt cleat
//    that runs across it and tends to stop where it meets the first.
//  - cast. The body leans a hair warm-brown in its darkest patches
//    (bituminous coal is never a pure neutral black) and the highlight
//    leans a hair cool, the way a hard glassy face always does.
//
// It stays dead still: no `seconds` anywhere. That is left for the coal
// once it is burning.

// Coal shears clean along a facet, not a rounded lump: roll the edge
// over fairly hard, short of metal.
#define M_ROLL 2.1

const vec3 COAL_BLACK  = vec3(0.058, 0.053, 0.060); // the body, cool near-black
const vec3 COAL_BROWN  = vec3(0.135, 0.092, 0.062); // the warm cast in the darkest, dullest patches
const vec3 COAL_CRACK  = vec3(0.006, 0.006, 0.008); // the cleats themselves, truly black
const vec3 COAL_SHEEN  = vec3(0.520, 0.570, 0.640); // the wide, duller glass sheen of a facet turning toward the light
const vec3 COAL_HILITE = vec3(0.800, 0.870, 1.000); // the hard glassy glint, a hair cool

const float COAL_FACET     = 0.20; // the facets, four to five cells across
const float COAL_TILT      = 1.35; // how hard a facet leans off the bevel
const float COAL_SEAM_IN   = 0.34; // where the gap between facets starts to show
const float COAL_SEAM_OUT  = 0.52; // where it is fully sunk
const float COAL_SHEEN_GLOSS = 24.0; // a whole facet's worth of glass, not a point
const float COAL_GLOSS     = 130.0; // narrow and hard: the glint on top of the sheen
const float COAL_SHEEN_STR  = 0.34;
const float COAL_HILITE_STR = 1.7;
const float COAL_FRES_POW  = 3.0;
const float COAL_RIM_STR   = 0.60;

// One family of cleats: parallel cracks at `angle`, `spacing` cells
// apart, `width` cells wide, walked off a straight line by `jitter` so
// they read as broken rock and not a ruled grid, and gated by a slow
// noise field so a crack fades out and picks up again down its own
// length instead of running the width of the world.
float coal_cleat(vec2 c, float angle, float spacing, float width,
                  float jitter, float broken, float seed)
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
    return line*gate;
}

vec3 shade(Surf s)
{
    // Break the bevel into flat plates: each facet, picked out by
    // `m_cells`, takes one constant tilt off its own hashed id, so the
    // highlight jumps from plate to plate instead of rolling across the
    // face the way a soft fbm bump would.
    vec3 f = m_cells(s.cell*COAL_FACET);
    vec2 id = f.yz;
    vec2 tilt = (m_hash2(id) - 0.5)*COAL_TILT;
    s.n = normalize(vec3(s.n.xy + tilt, s.n.z));

    // The gap at the edge of a facet sinks a hair, the way a real
    // conchoidal chip catches a shadow along its own rim.
    float seam = smoothstep(COAL_SEAM_IN, COAL_SEAM_OUT, f.x);

    // The two cleat families: a strong, fairly unbroken face cleat and a
    // fainter butt cleat running near-perpendicular to it, choppier
    // because it tends to stop dead against the first.
    float angle1 = 0.40;
    float c1 = coal_cleat(s.cell, angle1, 5.5, 0.55, 0.9, 0.15, 1.3);
    float c2 = coal_cleat(s.cell, angle1 + 1.55, 3.6, 0.34, 0.6, 0.70, 5.7)*0.85;
    float crack = clamp(c1 + c2, 0.0, 1.0);

    // Which kind of facet this one is: most faces are dead sooty matte,
    // a middle band carries a dull sheen, and only the rare best-turned
    // face is glassy enough to also hold the hard glint. The matte ones
    // sit a shade darker in the body and lean warmer; the glassy ones
    // lean a hair cool even unlit.
    float glass = m_hash(id + 5.0);
    float sheen_amt = smoothstep(0.34, 0.78, glass);
    float glint_amt = smoothstep(0.80, 0.94, glass);

    float warm = m_hash(id + 2.3);
    vec3 albedo = mix(COAL_BLACK, COAL_BROWN, warm*(1.0 - sheen_amt*0.7));
    albedo = mix(albedo, albedo*0.55, seam);
    albedo = mix(albedo, COAL_CRACK, crack);

    // Coal drinks almost all the light that reaches it: a thin, mostly
    // flat diffuse return. The read comes from the sheen and glint below.
    float ndl = m_diffuse(s);
    vec3 lit = albedo*(ndl*0.35 + 0.65);
    lit *= mix(0.50, 1.0, s.ao);

    // Each glassy facet throws back a whole plate's worth of dull mirror
    // where it turns toward the light, so the facets read as a jumble of
    // flat panes rather than a smooth roll — and on top of that, only
    // where a facet lines up almost exactly, the hard narrow glint.
    vec3 h = normalize(s.l + M_VIEW);
    float ndh = max(dot(s.n, h), 0.0);
    float sheen = pow(ndh, COAL_SHEEN_GLOSS)*sheen_amt;
    float glint = pow(ndh, COAL_GLOSS)*glint_amt;
    vec3 face = COAL_SHEEN*sheen*COAL_SHEEN_STR + COAL_HILITE*glint*COAL_HILITE_STR;
    face *= 1.0 - crack*0.95;

    // A cool glint along the broken rim of a lump or a vein, where a
    // conchoidal edge catches the light almost edge-on.
    float fres = m_fresnel(s, COAL_FRES_POW);
    vec3 rim = COAL_HILITE*fres*s.edge*COAL_RIM_STR*(0.35 + 0.65*sheen_amt);

    vec3 col = mix(lit, COAL_CRACK, crack) + face + rim;
    return m_dress(col, s);
}
