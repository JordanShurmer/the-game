// Wheat.
//
// A standing crop, and the thing a homeland is for. A stalk is a straw
// with an ear on the end of it, so the shader has to answer two
// questions at once: what a straw looks like, and where the ear is.
//
// `s.depth` answers the second for nothing. It is how many cells of the
// same material stand directly over this one, so it is small at the top
// of a stalk and grows all the way down it. The ear is where the depth
// is under WHEAT_EAR cells; everything under that is straw. Nothing has
// to be passed in and no second material is needed: one row in
// data/materials.txt is the whole crop.
//
// Three things carry the read:
//
//  - the straw. A hard vertical grain, pale gold, each stalk a shade
//    off its neighbour so a field is not one wash of yellow.
//  - the ear. Fatter, brighter, and grained across instead of along --
//    the grains sit in two ranks up the ear, so the field bumps the
//    light crosswise at the top and lengthwise below it.
//  - the awns. The whiskers off the top of an ear, which is the thing
//    that makes a wheatfield read as wheat and not as tall grass. They
//    are drawn as a bright ragged fringe where the crop meets air at
//    the very top of a stalk.

// Straw: no arris at all.
#define M_ROLL 0.72

const vec3 WHEAT_STRAW = vec3(0.660, 0.545, 0.230); // the stalk
const vec3 WHEAT_PALE  = vec3(0.790, 0.690, 0.360); // a stalk in the light
const vec3 WHEAT_SHADE = vec3(0.330, 0.262, 0.108); // the gap between stalks
const vec3 WHEAT_EAR_C = vec3(0.820, 0.680, 0.300); // the ear, ripe
const vec3 WHEAT_AWN   = vec3(0.930, 0.870, 0.560); // the whiskers off it
const vec3 WHEAT_GREEN = vec3(0.430, 0.470, 0.180); // a stalk not yet turned

const float WHEAT_EAR = 7.0;  // cells of ear at the top of a stalk
const float WHEAT_STALK = 3.1; // across the stalk: moves fast
const float WHEAT_RUN = 0.22;  // along it: barely moves
const float WHEAT_RELIEF = 1.25;

// How much of the ear this cell is: 1 at the very top of a stalk,
// falling away to 0 by WHEAT_EAR cells down it.
float wheat_ear(Surf s)
{
    return 1.0 - smoothstep(0.0, WHEAT_EAR, s.depth);
}

float wheat_straw_field(vec2 cell)
{
    return m_fbm(vec2(cell.x*WHEAT_STALK, cell.y*WHEAT_RUN), 3);
}

// The grains up an ear: banded across the stalk rather than along it.
float wheat_grain_field(vec2 cell)
{
    float band = fract(cell.y*0.42 + m_noise(cell*vec2(0.9, 0.2))*0.6);
    return 1.0 - abs(band*2.0 - 1.0);
}

float wheat_height(vec2 cell, float ear)
{
    float straw = wheat_straw_field(cell);
    float grain = wheat_grain_field(cell);
    return mix(straw, grain*0.8 + straw*0.4, ear);
}

vec3 shade(Surf s)
{
    float ear = wheat_ear(s);
    float straw = wheat_straw_field(s.cell);

    // The stalks: a hard vertical grain, dark in the gap between them.
    vec3 albedo = mix(WHEAT_SHADE, WHEAT_STRAW, smoothstep(0.22, 0.62, straw));
    albedo = mix(albedo, WHEAT_PALE, smoothstep(0.66, 0.92, straw));

    // A patch of the field still green, because a crop does not ripen
    // all at once and a field that has is a flat wash.
    float ripe = m_fbm(s.cell*0.021 + 8.0, 2);
    albedo = mix(albedo, WHEAT_GREEN, smoothstep(0.58, 0.86, ripe)*0.45);

    // The ear, and the grains banded up it.
    vec3 ear_col = mix(WHEAT_EAR_C*0.72, WHEAT_EAR_C*1.14, wheat_grain_field(s.cell));
    albedo = mix(albedo, ear_col, ear*0.85);

    // The awns: a bright ragged fringe off the top of the crop.
    float whisker = smoothstep(0.42, 0.86, m_noise(s.cell*vec2(2.4, 1.1) + 12.0));
    albedo = mix(albedo, WHEAT_AWN, whisker*ear*s.edge*0.70);

    float e = 0.8;
    float h  = wheat_height(s.cell, ear);
    float hx = wheat_height(s.cell + vec2(e, 0.0), ear);
    float hy = wheat_height(s.cell + vec2(0.0, e), ear);
    s.n = normalize(vec3(s.n.xy + vec2(h - hx, h - hy)*WHEAT_RELIEF, s.n.z));

    // Straw is hollow and thin: light comes through it as much as off
    // it, which is what gives a ripe field its glow.
    float ndl = m_diffuse(s);
    float wrap = ndl*0.56 + 0.44;
    float through = max(-dot(s.n, s.l), 0.0)*0.28;
    vec3 lit = albedo*(wrap + through);

    // A dry satin along the stalk, and a harder one across an ear.
    lit += WHEAT_PALE*m_spec_aniso(s, vec2(0.0, 1.0), 3.2, 0.34)*(1.0 - ear)*0.14;
    lit += WHEAT_AWN*m_spec(s, 26.0)*ear*0.16;

    // Down in the crop, under the ears, almost nothing reaches.
    lit *= mix(0.40, 1.04, s.ao);

    return m_dress(lit, s);
}
