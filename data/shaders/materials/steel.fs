// Steel.
//
// The other metal, and the opposite of gold in every way that matters.
// Gold is found: a rough mat of grains, warm, and never worked. Steel is
// made: rolled flat, ground in one direction, and bolted into plate. So
// it is written the way `gold.fs` is written — no diffuse term, a
// reflected room, a fresnel that goes white — with three differences.
//
//  - the tint is nearly neutral. Steel reflects a little over half of
//    every colour, a hair less red than blue, which is why it looks cold
//    beside gold's warmth.
//  - the highlight is a streak, not a lump. A ground surface is a mat of
//    parallel scratches, and a scratch reflects a line where a bump
//    would reflect a point. That one term is the whole difference
//    between metal that was made and metal that was found.
//  - it rusts. Clean steel reads as chrome, which is wrong for a mine;
//    the rust in the crevices and along the rim is what puts it in a
//    world with weather in it.
//
// The plate seams are deliberately quiet. They are the only regular
// thing in the game, and a strong grid reads as tiling, not as steel.

#define M_ROLL 2.4

const vec3 STEEL_F0 = vec3(0.440, 0.468, 0.520);
const vec3 STEEL_WHITE = vec3(0.960, 0.972, 1.000);
const vec3 STEEL_RUST = vec3(0.300, 0.132, 0.052);

const float STEEL_ROUGH = 0.190;  // ground, not polished
const float STEEL_DARK = 0.070;   // what it reflects facing away
const float STEEL_BRIGHT = 0.980; // what it reflects facing the lamp

const float STEEL_GRIND = 2.30;   // the scratches, better than half a cell
const float STEEL_ROLL_WAVE = 0.055; // the long swell the rolling mill leaves
const float STEEL_PLATE = 17.0;   // cells across a plate
const float STEEL_SEAM = 0.13;    // how much of a plate the seam takes
const float STEEL_SEAM_STR = 0.10; // and how hard it is drawn

// The grinding scratches, drawn out hard along the grain, plus the slow
// swell the rolling mill leaves under them.
// The grind, the slow swell the rolling mill leaves, and the dents a
// working life beats into a plate. The dents are what the light swings
// across: without them the plate reads as paint, not metal.
float steel_face_height(vec2 c)
{
    float grind = m_fbm(vec2(c.x*0.11, c.y*STEEL_GRIND), 3);
    float swell = m_fbm(c*STEEL_ROLL_WAVE, 3);
    float dent = m_fbm(c*0.13 + 5.3, 3);
    return grind*0.16 + swell*0.36 + dent*1.15;
}

// Where in its plate a cell lies, 0 in the middle and 1 at the seam.
float steel_seam(vec2 c)
{
    vec2 p = abs(fract(c/STEEL_PLATE) - 0.5)*2.0;
    float edge = max(p.x, p.y);
    return smoothstep(1.0 - STEEL_SEAM, 1.0, edge);
}

float steel_ggx(vec3 n, vec3 h, float rough)
{
    float a = rough*rough;
    float ndh = max(dot(n, h), 0.0);
    float d = ndh*ndh*(a*a - 1.0) + 1.0;
    return (a*a)/(3.14159265*d*d);
}

vec3 shade(Surf s)
{
    float seam = steel_seam(s.cell);

    float e = 0.8;
    float h0 = steel_face_height(s.cell);
    float hx = steel_face_height(s.cell + vec2(e, 0.0));
    float hy = steel_face_height(s.cell + vec2(0.0, e));
    vec2 slope = vec2(h0 - hx, h0 - hy)*3.3;

    // The seam dips, but only a little: a plate joint, not a trench.
    slope.y += seam*STEEL_SEAM_STR;

    vec3 n = normalize(vec3(s.n.xy + slope, s.n.z*0.94 + 0.10));
    vec3 h = normalize(s.l + M_VIEW);
    float ndl = max(dot(n, s.l), 0.0);
    float ndv = max(dot(n, M_VIEW), 0.0);

    vec3 fresnel = STEEL_F0 + (STEEL_WHITE - STEEL_F0)*pow(1.0 - max(dot(h, M_VIEW), 0.0), 5.0);

    // The lamp, reflected twice over: once as a round point off the
    // shape, and once drawn out into a line by the grinding. The streak
    // is the one that says the plate was ground.
    float point = steel_ggx(n, h, STEEL_ROUGH);

    // The streak breaks where the scratches do, or it reads as bands
    // laid across the plate instead of light caught in the grind.
    float catch = 0.45 + 0.55*m_noise(vec2(s.cell.x*0.15, s.cell.y*1.1));
    float streak = m_spec_aniso(s, vec2(1.0, 0.0), 0.55, 0.24)*catch;

    float shadow = ndl/(ndl*0.6 + 0.4);
    vec3 lamp = fresnel*(point*0.40 + streak*0.85)*shadow;

    // The room, reflected. As with gold, this swing from bright to dark
    // across the surface is what makes metal read as metal.
    float toward = dot(n, s.l)*0.5 + 0.5;
    float sky = mix(0.50, 1.0, s.ao);
    vec3 env = STEEL_F0*mix(STEEL_DARK, STEEL_BRIGHT, pow(toward, 2.3))*sky;

    // Rust gathers where the water sits: in the seams, in the crevices,
    // and along the broken rim. It kills the mirror wherever it takes.
    // The seam only rusts where the weather found it, or every joint
    // draws itself and the wall reads as graph paper.
    float weather = m_fbm(s.cell*0.075, 4);
    float damp = seam*smoothstep(0.35, 0.75, weather)*0.55
               + (1.0 - s.ao)*0.45 + s.edge*0.35;
    float rust = smoothstep(0.52, 0.98, weather*0.55 + damp*0.62);
    vec3 scab = STEEL_RUST*(0.35 + 0.65*max(dot(s.n, s.l), 0.0));

    vec3 metal = lamp + env;
    metal = mix(metal, scab, rust*0.45);

    // The broken lip of a plate, where the steel rolls away from the eye.
    metal += STEEL_WHITE*pow(1.0 - ndv, 3.2)*0.26*s.edge*(1.0 - rust*0.7);

    return m_dress(metal, s);
}
