// Gold.
//
// Metal is not a colour, it is a way of answering light. A yellow rock
// gives back a little of every colour that falls on it, evenly, in every
// direction. Gold gives back almost nothing evenly: what leaves it is a
// narrow reflection of whatever lit it, tinted by the metal itself. So
// this shader has no diffuse term at all. Everything the eye sees here
// is a reflection.
//
// Three things then tell the eye it is gold and not chrome:
//
//  - the tint. Gold reflects nearly all the red that falls on it, three
//    quarters of the green and a third of the blue. Those are the three
//    numbers in GOLD_F0, and they are measured, not chosen.
//  - the reflection widens and goes white at a glancing angle, because
//    every surface does. That is the rim on the far side of a nugget.
//  - the surface is not flat at the size of a cell. Native gold is a mat
//    of grains laid in rock, so the reflection breaks into lumps, and
//    now and then one grain turns its face to the lamp and burns.

// Metal rolls its edge over hard: the rim of a nugget is a small, bright
// band, not a soft shoulder.
#define M_ROLL 2.6

const vec3 GOLD_F0 = vec3(1.000, 0.766, 0.336);
const vec3 GOLD_WHITE = vec3(1.000, 0.955, 0.880);

const float GOLD_LUMP = 0.075;  // the nuggets in the mat, about 13 cells
const float GOLD_GRAIN = 0.34;  // the grains in a nugget, about 3 cells
const float GOLD_RELIEF = 2.6;  // how deep the lumps cut
const float GOLD_ROUGH = 0.235; // a worked face, not a mirror
const float GOLD_DARK = 0.085;  // what the metal reflects facing away
const float GOLD_BRIGHT = 0.92; // what it reflects facing the lamp
const float GOLD_SPARK = 1.55;
const vec3 GOLD_PALE = vec3(1.000, 0.905, 0.660); // gold that carries silver

// The lumps and the grain of a mat of native gold.
float gold_height(vec2 c)
{
    return m_fbm(c*GOLD_LUMP*0.35, 3)*1.35
         + m_fbm(c*GOLD_LUMP, 4)
         + m_ridge(c*GOLD_GRAIN, 3)*0.30
         + m_noise(c*1.7)*0.05;
}

// The bevel of the vein with the lumps of the metal laid over it.
vec3 gold_face(Surf s)
{
    float e = 0.85;
    float h  = gold_height(s.cell);
    float hx = gold_height(s.cell + vec2(e, 0.0));
    float hy = gold_height(s.cell + vec2(0.0, e));

    vec2 slope = vec2(h - hx, h - hy)*GOLD_RELIEF;
    return normalize(vec3(s.n.xy + slope, s.n.z*0.92 + 0.10));
}

// How much of the light a rough face throws back toward the eye.
float gold_ggx(vec3 n, vec3 h, float rough)
{
    float a = rough*rough;
    float ndh = max(dot(n, h), 0.0);
    float d = ndh*ndh*(a*a - 1.0) + 1.0;
    return (a*a)/(3.14159265*d*d);
}

vec3 shade(Surf s)
{
    vec3 n = gold_face(s);
    vec3 h = normalize(s.l + M_VIEW);

    float ndl = max(dot(n, s.l), 0.0);
    float ndv = max(dot(n, M_VIEW), 0.0);

    // Every surface turns into a mirror at a glancing angle, and a mirror
    // has no colour. This is what puts the white line on the rim.
    vec3 fresnel = GOLD_F0 + (GOLD_WHITE - GOLD_F0)*pow(1.0 - max(dot(h, M_VIEW), 0.0), 5.0);

    // The lamp, reflected.
    float lobe = gold_ggx(n, h, GOLD_ROUGH);
    float shadow = ndl/(ndl*0.6 + 0.4);
    vec3 lamp = fresnel*lobe*shadow*0.55;

    // The room, reflected. This is what makes metal look like metal and
    // not like paint: a mirror shows the bright half of the room where it
    // faces the lamp and the dark half where it faces away, so the lumps
    // of the mat swing from near white to near black across a few cells.
    // Paint would only shade gently between the two.
    float toward = dot(n, s.l)*0.5 + 0.5;
    float sky = mix(0.55, 1.0, s.ao);

    // Native gold is never one colour. Where it carries silver it goes
    // pale, and the two run in patches a nugget wide.
    vec3 alloy = mix(GOLD_F0, GOLD_PALE, smoothstep(0.42, 0.72, m_fbm(s.cell*0.045, 3)));
    vec3 env = alloy*mix(GOLD_DARK, GOLD_BRIGHT, pow(toward, 1.7))*sky;

    // The rim of the vein, where the metal rolls away from the eye and
    // the reflection goes wide and pale.
    vec3 rim = GOLD_WHITE*pow(1.0 - ndv, 3.4)*0.42*s.edge;

    // Now and then one grain turns its face to the lamp and burns. This
    // is why a vein of gold reads as gold from across a dark cave.
    float spark = m_glint(s.cell, 0.62, 1.7, 0.90);
    vec3 burn = mix(GOLD_F0, GOLD_WHITE, 0.55)*spark*GOLD_SPARK;

    return m_dress(lamp + env + rim + burn, s);
}
