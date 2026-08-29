// Ice.
//
// Ice is not a white material: it is a nearly clear solid, and every
// colour it shows is borrowed. Look through a thin pane of it and there
// is almost nothing there but the room beyond, tinted only faintly.
// Look into the middle of a thick block and the light that entered has
// crossed cell after cell of the stuff and been filtered blue each time,
// so the body glows cyan in its depths while its rim stays colourless.
// That is `s.depth` and `s.bury` at work, not a fixed tint.
//
// The other half of ice is the mirror it turns into at a glancing angle.
// Head on, almost all the light passes through; near the rim, almost
// all of it bounces off, bright and hard. That swing, `m_fresnel`, plus
// a tight, sharp specular highlight, is most of what says "ice" rather
// than "white plastic". Frozen into the body are the flaws that come
// with freezing fast: bubbles trapped as points of light and long, flat
// cracks that catch the lamp only from one angle. Both stay below the
// surface, never drawn over the rim itself.

// Cold and sharp: a small, hard-edged rim, not a soft shoulder.
#define M_ROLL 2.2

const vec3 ICE_DEEP   = vec3(0.130, 0.440, 0.660); // the cyan-blue of a thick body
const vec3 ICE_THIN   = vec3(0.850, 0.930, 0.930); // almost colourless at the rim
const vec3 ICE_FROST  = vec3(0.930, 0.970, 0.985); // the frosted rim against air
const vec3 ICE_BUBBLE = vec3(0.960, 0.985, 1.000);

const float ICE_CRACK  = 0.065; // long fracture planes, tens of cells
const float ICE_BUBBLE_SCALE = 0.85; // trapped bubbles, about a cell

// One family of long, straight fracture planes on a given axis. The
// body is combed into parallel strips across that axis; only a few of
// the strips are picked to actually carry a crack, so what shows is a
// few long lines and not a repeating grid.
float ice_crack_family(vec2 c, vec2 axis, float seed)
{
    vec2 across = vec2(-axis.y, axis.x);
    float along = dot(c, axis)*ICE_CRACK;
    float bow = dot(c, across)*ICE_CRACK;
    float drift = m_fbm(vec2(along*0.25, seed), 2)*1.1;

    float line = floor(bow - drift);
    float has = step(0.86, m_hash(vec2(line, seed)));
    float d = abs(fract(bow - drift) - 0.5);
    return has*(1.0 - smoothstep(0.0, 0.05, d));
}

// A few long, faint, straight fracture planes deep in the body, on two
// crossing axes so a shattered block reads as more than one crack.
float ice_crack(vec2 c)
{
    float a = ice_crack_family(c, vec2(0.86, 0.51), 7.0);
    float b = ice_crack_family(c, vec2(0.36, -0.93), 21.0);
    return max(a, b);
}

// Trapped bubbles: small, bright, round points scattered through the
// body, never on the surface itself.
float ice_bubble(vec2 c)
{
    vec3 p = m_cells(c*ICE_BUBBLE_SCALE + 31.0);
    float pick = step(0.90, m_hash(p.yz + 6.0));
    float near = 1.0 - smoothstep(0.0, 0.18, p.x);
    return pick*near*near;
}

vec3 shade(Surf s)
{
    vec3 n = s.n;

    float ndl = max(dot(n, s.l), 0.0);
    float ndv = max(dot(n, M_VIEW), 0.0);

    // The body colour comes from depth, not from a fixed tint: a thin
    // rim shows almost nothing but what is behind it, a thick body glows
    // cyan in its middle. `bury` keeps a lone cell or a thin vein from
    // ever reading as a deep, glowing block.
    float thick = clamp(s.depth/10.0, 0.0, 1.0)*s.bury;
    vec3 body = mix(ICE_THIN, ICE_DEEP, thick);

    // Strong wrap: light scatters a little inside the ice itself before
    // it leaves, so the shadow side never goes fully cold and dark.
    float wrap = ndl*0.55 + 0.45;
    vec3 col = body*wrap;

    // The fracture planes: faint where the body is thin, more visible
    // deep inside a thick block, and only ever below the surface.
    float crack = ice_crack(s.cell)*thick*0.5;
    col = mix(col, col*0.72 + ICE_THIN*0.30, crack);

    // The trapped bubbles: small bright points, kept out of the rim so
    // they never look like they are sitting on the surface.
    float bubble = ice_bubble(s.cell)*s.bury;
    col = mix(col, ICE_BUBBLE, bubble*0.85);

    // Fresnel: nearly clear head on, a hard bright mirror at a glancing
    // angle. This is most of what makes it read as ice.
    float fres = m_fresnel(s, 4.2);
    col = mix(col, ICE_FROST, fres*0.75);

    // A tight, hard specular point where the lamp catches the surface
    // square on — the one sharp highlight a wet or glassy face gives.
    float spec = m_spec(s, 220.0);
    col += ICE_FROST*spec*0.9;

    // A softer, wider glint further out, the kind a slightly uneven
    // frozen face throws even off-axis.
    float wide = m_spec(s, 40.0);
    col += ICE_THIN*wide*0.12;

    // The frosted rim where the body meets open air: a thin, bright,
    // near-white line right at the edge.
    float rim = pow(1.0 - ndv, 5.0)*s.edge;
    col += ICE_FROST*rim*0.35;

    return m_dress(col, s);
}
