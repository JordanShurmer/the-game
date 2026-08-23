// Thatch.
//
// A roof of reed, laid in courses from the eaves up, every course
// overlapping the one below it so what the weather sees is only the cut
// butt ends of the topmost layer. So the read is not a smooth skin: it
// is a stack of shallow steps, each one a band of packed straw ends,
// with a shadow line under it.
//
// The courses must lie along the slope of the roof, and a shader is not
// told which way that is -- but it does not have to be. `s.n` faces out
// of the body of thatch, so the direction across the roof is `s.n`
// turned a right angle, and everything here is laid out in that frame.
// The same file then draws the near slope, the far slope and a rick in
// a field correctly, without knowing that any of them exist.
//
// Three things carry the read:
//
//  - the courses. Bands THATCH_COURSE cells apart across the slope,
//    each with a dark line under its butt end.
//  - the straw. Fine fibres along the lie of the reed, pale where they
//    are freshly cut and grey where the weather has had them.
//  - the ragged edge. Where the thatch meets air the reed ends stand
//    out singly, so the eaves and the ridge are never a ruled line.

// Straw: no crisp arris. It rolls off soft, softer even than powder.
#define M_ROLL 0.7

const vec3 THATCH_STRAW = vec3(0.700, 0.545, 0.250); // new reed, in the sun
const vec3 THATCH_DEEP  = vec3(0.360, 0.262, 0.115); // the shadow between courses
const vec3 THATCH_GREY  = vec3(0.430, 0.400, 0.330); // reed the weather has had
const vec3 THATCH_MOSS  = vec3(0.250, 0.320, 0.190); // what grows on a north slope

const float THATCH_COURSE = 9.0;  // cells from one course of reed to the next
const float THATCH_FIBRE  = 2.3;  // how fine the straw grain is
const float THATCH_RELIEF = 1.35; // how much the courses bump the light

// The frame of the roof: `along` runs with the lie of the reed and
// `across` runs up the slope, from the eaves to the ridge.
void thatch_frame(Surf s, out vec2 along, out vec2 across)
{
    vec2 n = s.n.xy;
    if (length(n) < 0.06) n = vec2(0.0, -1.0); // deep inside: call it flat
    across = normalize(n);
    along = vec2(-across.y, across.x);
}

// How far into a course this cell is, 0 at the butt end of one and 1
// just under the next. The course line itself wanders, because reed is
// laid by hand and no two bundles are the same thickness.
float thatch_course(vec2 cell, vec2 along, vec2 across)
{
    float up = dot(cell, across);
    float side = dot(cell, along);
    up += m_fbm(vec2(side*0.10, up*0.02), 2)*3.4;
    return fract(up/THATCH_COURSE);
}

float thatch_height(vec2 cell, vec2 along, vec2 across)
{
    float c = thatch_course(cell, along, across);
    // A course is a shallow wedge: thin where it starts, thick at the
    // butt end where the next one laps over it.
    float step_h = smoothstep(0.0, 0.75, c);
    float fibre = m_noise(vec2(dot(cell, along)*THATCH_FIBRE, dot(cell, across)*0.30));
    return step_h*0.85 + fibre*0.30;
}

vec3 shade(Surf s)
{
    vec2 along, across;
    thatch_frame(s, along, across);

    float side = dot(s.cell, along);
    float up = dot(s.cell, across);
    float c = thatch_course(s.cell, along, across);

    // The straw itself: long fine fibres, each a shade off its
    // neighbour, drawn out hard along the lie of the reed.
    float grain = m_fbm(vec2(side*THATCH_FIBRE, up*0.16), 4);
    vec3 albedo = mix(THATCH_DEEP, THATCH_STRAW, smoothstep(0.24, 0.78, grain));

    // Weathering: a slow patch of grey where the rain sits, and moss in
    // the deepest of it.
    float weather = m_fbm(s.cell*0.030 + 21.0, 3);
    albedo = mix(albedo, THATCH_GREY, smoothstep(0.46, 0.80, weather)*0.60);
    albedo = mix(albedo, THATCH_MOSS, smoothstep(0.70, 0.92, weather)*0.35);

    // The shadow line under the butt end of every course.
    albedo = mix(albedo, THATCH_DEEP, smoothstep(0.16, 0.0, c)*0.75);

    // Cut ends standing single at the edge of the thatch, so the eaves
    // and the ridge are ragged and never ruled.
    float ragged = smoothstep(0.52, 0.86, m_noise(vec2(side*1.7, up*0.7) + 6.0));
    albedo = mix(albedo, THATCH_STRAW*1.20, ragged*s.edge*0.55);

    float e = 0.85;
    float h  = thatch_height(s.cell, along, across);
    float hx = thatch_height(s.cell + vec2(e, 0.0), along, across);
    float hy = thatch_height(s.cell + vec2(0.0, e), along, across);
    s.n = normalize(vec3(s.n.xy + vec2(h - hx, h - hy)*THATCH_RELIEF, s.n.z));

    // Straw scatters rather than reflects: a wide wrap, and no mirror
    // in it at all beyond a dry satin along the fibre.
    float ndl = m_diffuse(s);
    vec3 lit = albedo*(ndl*0.66 + 0.34);
    lit += THATCH_STRAW*m_spec_aniso(s, along, 3.0, 0.42)*0.16;

    // Deep in the thatch no light gets between the reeds at all.
    lit *= mix(0.52, 1.0, s.ao);
    lit *= mix(1.0, 0.78, s.bury);

    return m_dress(lit, s);
}
