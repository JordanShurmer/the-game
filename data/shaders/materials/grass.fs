// Grass.
//
// A sward is not a green surface: it is several thousand blades stood
// on end, and what the eye reads at any distance is the tips of them.
// So the whole shader is built on one field stretched hard across the
// blade and barely at all along it, the way `wood.fs` is built on a
// field stretched along the fibre -- the same trick, turned ninety
// degrees, because a blade of grass stands up and a plank lies down.
//
// Three things carry the read:
//
//  - the blades. Fine vertical striations, each a shade off its
//    neighbour, so a patch is never one flat green.
//  - the season. A slow patch of colour, tens of cells wide, running
//    from the deep green of shaded turf through meadow green to the dry
//    straw-green of a bank that has been in the sun. A homeland is
//    grazed and mown, not a lawn.
//  - the tips. The topmost cells of a body of grass catch nearly all
//    the light there is; the roots of it are in its own shade. `s.top`
//    and `s.ao` carry that, and it is what stops a bank of grass
//    reading as flat paint.
//
// A crown of leaves on a tree is grass too -- the world has one green
// material -- so the tip lightening must work face-on as well as along
// a horizon, which is why it rides on `s.ao` and not on `s.n.y`.

// A blade rolls over at once: soft, softer than powder.
#define M_ROLL 0.75

const vec3 GRASS_DEEP = vec3(0.118, 0.230, 0.098); // turf in its own shade
const vec3 GRASS_MID  = vec3(0.238, 0.400, 0.152); // the common meadow green
const vec3 GRASS_SUN  = vec3(0.420, 0.520, 0.190); // a bank the sun has had
const vec3 GRASS_DRY  = vec3(0.560, 0.500, 0.245); // and where it has gone over
const vec3 GRASS_TIP  = vec3(0.560, 0.680, 0.300); // the lit tip of a blade

const float GRASS_BLADE = 2.9;  // across the blade: moves fast
const float GRASS_RUN   = 0.30; // along it: barely moves
const float GRASS_PATCH = 0.026; // the slow colour drift, tens of cells
const float GRASS_RELIEF = 1.05;

// The stretched field the blades are cut from.
float grass_field(vec2 cell)
{
    return m_fbm(vec2(cell.x*GRASS_BLADE, cell.y*GRASS_RUN), 3);
}

// Which green this patch of ground is: shaded turf, meadow, sun-bleached
// or gone over to seed. Two patches at different scales, so the drift is
// not one smooth ramp across a whole field.
vec3 grass_patch(vec2 cell)
{
    float p = m_fbm(cell*GRASS_PATCH, 2);
    p = clamp((p - 0.5)*2.2 + 0.5, 0.0, 1.0);
    vec3 col = mix(GRASS_DEEP, GRASS_MID, smoothstep(0.18, 0.62, p));
    col = mix(col, GRASS_SUN, smoothstep(0.58, 0.92, p));

    float dry = m_fbm(cell*GRASS_PATCH*2.3 + 61.0, 2);
    return mix(col, GRASS_DRY, smoothstep(0.66, 0.90, dry)*0.55);
}

float grass_height(vec2 cell)
{
    return grass_field(cell)*0.9 + m_noise(cell*vec2(1.4, 0.5))*0.2;
}

vec3 shade(Surf s)
{
    float blades = grass_field(s.cell);
    vec3 albedo = grass_patch(s.cell);

    // Blade against blade: the near one pale, the gap behind it dark.
    albedo *= mix(0.62, 1.28, smoothstep(0.20, 0.80, blades));

    // Seed heads and dead stems, a single cell here and there.
    vec3 seed = m_cells(s.cell*vec2(1.6, 0.9));
    float pick = m_hash(seed.yz + 4.4);
    albedo = mix(albedo, GRASS_DRY, smoothstep(0.28, 0.0, seed.x)*step(0.90, pick)*0.7);

    float e = 0.8;
    float h  = grass_height(s.cell);
    float hx = grass_height(s.cell + vec2(e, 0.0));
    float hy = grass_height(s.cell + vec2(0.0, e));
    s.n = normalize(vec3(s.n.xy + vec2(h - hx, h - hy)*GRASS_RELIEF, s.n.z));

    // Grass is thin, so light goes through a blade as well as off it: a
    // wide wrap, and a little of the light coming from behind.
    float ndl = m_diffuse(s);
    float wrap = ndl*0.58 + 0.42;
    float through = max(-dot(s.n, s.l), 0.0)*0.20;

    vec3 lit = albedo*(wrap + through);

    // The tips, and the shade at the roots. This is most of the read.
    lit = mix(lit, GRASS_TIP*(wrap + through), s.ao*s.edge*0.45);
    lit *= mix(0.44, 1.06, s.ao);
    lit *= mix(0.92, 1.10, s.top);

    // A wet sheen after dew, only on the open face of a sward.
    lit += vec3(0.72, 0.82, 0.55)*m_spec(s, 22.0)*s.ao*0.10;

    return m_dress(lit, s);
}
