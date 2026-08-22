// Dirt.
//
// Loose earth: countless small clods heaped one on another, never one
// continuous face. There is no such thing as a flat plane of dirt at the
// size of a cell, so this shader never goes for a sharp bevel — it rolls
// soft (M_ROLL below 1) and gives the clods themselves real relief: a
// height field bumps the surface normal, so light rounds each lump off
// and settles into the gap beside it, the way it would a heap of small
// round things and not a painted pattern.
//
// Colour comes in three layers, coarse to fine:
//   - a slow patch of red-brown, grey-brown and near-black earth, tens of
//     cells wide, so a heap is not one flat colour;
//   - the clods themselves, a shade darker in the gap between lumps;
//   - flecks at one cell: pale grit, dark humus, the odd root.
//
// Dirt has almost no sheen. What little it has is a damp one, and only
// deep inside a body where earth would hold water — never at a lone
// cell or a thin rim.

// Powder: no crisp rim, a soft rolled shoulder instead.
#define M_ROLL 0.85

const vec3 DIRT_RED   = vec3(0.388, 0.247, 0.165); // the base earth, red-brown
const vec3 DIRT_GREY  = vec3(0.243, 0.216, 0.196); // a cooler, ashier patch
const vec3 DIRT_DARK  = vec3(0.095, 0.074, 0.060); // near-black humus patch
const vec3 DIRT_GRIT  = vec3(0.560, 0.514, 0.446); // pale flecks of stone
const vec3 DIRT_ROOT  = vec3(0.420, 0.333, 0.192); // a rare warm root fibre

const float DIRT_PATCH  = 0.032; // the slow colour drift, tens of cells
const float DIRT_CLOD   = 0.42;  // the lumps, two to three cells across
const float DIRT_FLECK  = 1.35;  // the grit, about one cell
const float DIRT_RELIEF = 1.15;  // how much the lumps bump the light

// Which of the three earth colours this patch of ground is.
vec3 dirt_patch_color(vec2 c)
{
    float p = m_fbm(c*DIRT_PATCH, 3);
    vec3 col = mix(DIRT_RED, DIRT_GREY, smoothstep(0.34, 0.66, p));
    float dark = m_fbm(c*DIRT_PATCH*1.9 + 40.0, 3);
    return mix(col, DIRT_DARK, smoothstep(0.62, 0.86, dark)*0.85);
}

// A dome for every clod, round off at its rim, with a little grain on
// top so no two lumps sit at quite the same height.
float dirt_height(vec2 c)
{
    vec3 h = m_cells(c*DIRT_CLOD);
    float dome = 1.0 - smoothstep(0.0, 0.68, h.x);
    dome *= dome;
    return dome + m_noise(c*2.1)*0.10;
}

// The clods bump the surface normal, so a lump catches the light on its
// crown and the gap beside it falls into its own small shadow.
vec3 dirt_face(Surf s)
{
    float e = 0.9;
    float h  = dirt_height(s.cell);
    float hx = dirt_height(s.cell + vec2(e, 0.0));
    float hy = dirt_height(s.cell + vec2(0.0, e));
    vec2 slope = vec2(h - hx, h - hy)*DIRT_RELIEF;
    return normalize(vec3(s.n.xy + slope, s.n.z));
}

vec3 shade(Surf s)
{
    vec3 n = dirt_face(s);

    vec3 hp = m_cells(s.cell*DIRT_CLOD);
    vec2 clod_id = hp.yz;

    // Each clod carries its own little offset off the base earth colour,
    // so no two lumps in a heap are quite the same.
    float clod_tone = m_hash(clod_id)*2.0 - 1.0;
    vec3 earth = dirt_patch_color(s.cell);
    earth *= 1.0 + clod_tone*0.09;

    // The seam between clods sinks a shade darker and duller.
    float seam = smoothstep(0.42, 0.80, hp.x);
    earth *= mix(1.0, 0.72, seam);

    // Grit and humus flecks at the size of a single cell.
    vec3 fleck_p = m_cells(s.cell*DIRT_FLECK);
    float fleck_h = m_hash(fleck_p.yz + 7.0);
    float fleck_near = smoothstep(0.22, 0.0, fleck_p.x);
    earth = mix(earth, DIRT_GRIT, fleck_near*step(0.90, fleck_h));
    earth = mix(earth, DIRT_ROOT, fleck_near*step(0.965, fleck_h + 0.02));

    // Diffuse light only — dirt has no mirror in it at all. A soft wrap
    // so powder never goes fully black on its own shadow side.
    float ndl = max(dot(n, s.l), 0.0);
    float wrap = ndl*0.70 + 0.30;

    // The crown of a heap catches the light; the body behind it goes dark
    // in its own shadow, deepened again where the sky above is shut out.
    float crown = mix(0.88, 1.16, s.top);
    float shadow = mix(0.60, 1.0, s.ao);

    vec3 lit = earth*wrap*crown*shadow;

    // A faint damp sheen, only deep inside a buried body, never at a rim
    // or a lone cell.
    float damp = clamp(s.bury*s.depth*0.05, 0.0, 1.0);
    float wet = pow(max(dot(n, normalize(s.l + M_VIEW)), 0.0), 16.0)*damp*0.09;

    return m_dress(lit + vec3(wet), s);
}
