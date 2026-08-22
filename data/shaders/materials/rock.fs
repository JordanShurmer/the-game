// Rock.
//
// The stone the coal-mine caves are cut out of, and the single most-seen
// material in the game. It has to disappear into the background the way
// a real wall does: a diffuse body with almost no mirror in it, its
// colour set once and for all by what it is made of, and its light
// carried entirely by how broken the face is. Where gold answers light
// with a reflection of the room, rock answers with a slope: a bump
// height field of fracture and bedding, whose gradient bends the normal
// before a single ray is dotted with anything.
//
// Three things carry the read:
//
//  - relief. A face broken along a fracture plane, chipped at the size
//    of a handful of cells, granular at the size of one. `m_ridge` gives
//    the planes, `m_fbm` the chipping, and a fine `m_noise` the grain.
//  - speckle. Grey stone is quartz and iron and mica, not one grey.
//    `m_cells` scatters pale and dark grains a cell or two across.
//  - strata. Faint bands, tilted a little, fixed in world space, so a
//    wall reads as cut stone and not as a slab of noise.
//
// It stays dead still: no `seconds` anywhere. Rock is the wall behind
// every wizard and every vein of ore in the game, and if it moves or
// flares it drags the eye off whatever is actually happening.

// Powder-soft, not metal-hard: stone chips at a rounded edge, not a
// knife one.
#define M_ROLL 1.15

const vec3 ROCK_BASE  = vec3(0.420, 0.420, 0.420); // the flat colour it replaces
const vec3 ROCK_DARK  = vec3(0.255, 0.248, 0.240); // iron-stained, in the crevices
const vec3 ROCK_PALE  = vec3(0.560, 0.548, 0.520); // quartz, a shade warm
const vec3 ROCK_DAMP  = vec3(0.360, 0.400, 0.410); // wet stone, cool and darker

const float ROCK_PLANE  = 0.145; // fracture planes, about 7 cells
const float ROCK_CHIP   = 0.052; // the chipping between planes, about 19 cells
const float ROCK_GRAIN  = 0.90;  // the granular face, about 1 cell
const float ROCK_RELIEF = 2.35;  // how deep the bump reads
const float ROCK_STRATA = 0.085; // spacing of the bedding, tilted

// The height field: broad fracture planes, a chip of fbm knocked over
// them, and a fine grain so the face never goes smooth.
float rock_height(vec2 c)
{
    float planes = m_ridge(c*ROCK_PLANE, 3);
    float chip   = m_fbm(c*ROCK_CHIP, 4);
    float grain  = m_noise(c*ROCK_GRAIN)*0.5 + m_noise(c*ROCK_GRAIN*2.3)*0.25;
    return planes*0.85 + chip*1.05 + grain*0.30;
}

// The bump normal: the g-buffer bevel with the broken face laid over it.
vec3 rock_normal(Surf s)
{
    float e = 0.8;
    float h  = rock_height(s.cell);
    float hx = rock_height(s.cell + vec2(e, 0.0));
    float hy = rock_height(s.cell + vec2(0.0, e));

    vec2 slope = vec2(h - hx, h - hy)*ROCK_RELIEF;
    return normalize(vec3(s.n.xy + slope, s.n.z));
}

// Faint bedding, tilted a little, fixed in world space so it stays put
// on the wall as the camera moves past it.
float rock_strata(vec2 c)
{
    float band = (c.x*0.18 + c.y)*ROCK_STRATA*6.2831853;
    float w = sin(band) + sin(band*2.03 + 1.7)*0.35;
    // a little of the chip noise breaks the lines up so they read as bedding
    // worn by fracture, not as a printed stripe.
    w += (m_noise(c*ROCK_CHIP*3.0) - 0.5)*0.6;
    return w*0.5 + 0.5;
}

// Grains of paler quartz and darker iron scattered through the body, one
// to three cells across.
vec3 rock_speckle(vec2 c)
{
    vec3 fine = m_cells(c*0.85);
    vec3 coarse = m_cells(c*0.34 + 11.0);

    float quartz = smoothstep(0.46, 0.0, fine.x)*step(0.45, m_hash(fine.yz));
    float iron   = smoothstep(0.50, 0.0, coarse.x)*step(0.55, m_hash(coarse.yz + 4.0));

    vec3 col = mix(ROCK_BASE, ROCK_PALE, quartz);
    col = mix(col, ROCK_DARK, iron*0.85);
    return col;
}

vec3 shade(Surf s)
{
    // Bend the normal the g-buffer gave us with the broken face, and
    // work with that from here on: everything below reads s.n as the
    // bumped normal, the way m_diffuse and m_spec expect.
    s.n = rock_normal(s);

    // The body colour: base stone, specked with grain, banded with
    // bedding, and dimmed in the crevices ao already found for us.
    vec3 albedo = rock_speckle(s.cell);
    float strata = rock_strata(s.cell);
    albedo = mix(albedo*0.82, albedo*1.12, strata);

    // Damp stone runs cooler and a little darker; it gathers low, deep
    // inside a body, away from the open air.
    float damp = (1.0 - s.ao)*s.bury*0.5;
    albedo = mix(albedo, ROCK_DAMP, damp*0.35);

    // A diffuse face: most of what leaves it is scattered evenly, so the
    // colour itself barely swings. What moves is how much of it returns,
    // which is why the relief above has to carry the read.
    float ndl = m_diffuse(s);
    float wrap = ndl*0.85 + 0.15; // stone never quite goes to black itself
    vec3 lit = albedo*wrap;

    // A weak, wide sheen, more where the stone runs damp; nothing like a
    // metal's mirror, just enough to say the face isn't chalk.
    float gloss = mix(7.0, 26.0, damp);
    float sheen = m_spec(s, gloss);
    lit += vec3(0.85, 0.90, 0.95)*sheen*mix(0.05, 0.16, damp);

    // Ambient occlusion sinks the inside of a crack, and the crest of a
    // boulder catches a hair more of the open sky.
    lit *= mix(0.48, 1.0, s.ao);

    // A lit, worn rim where the stone meets open air: the bevel catches
    // the light along the edge of a boulder or the lip of a crack.
    float rim = pow(1.0 - max(s.n.z, 0.0), 2.6)*s.edge*max(dot(s.n, s.l), 0.0);
    lit += ROCK_PALE*rim*0.30;

    return m_dress(lit, s);
}
