// Wood.
//
// Timber is a bundle of fibres, not a lump. Everything here follows from
// that one fact: the noise that carries the colour and the bump that
// carries the light are both built from a coordinate stretched hard
// along the length of the fibre and squeezed hard across it, so the
// field draws out into long grain instead of round blobs. Growth rings
// come free from the same field — a wood shader does not need a second
// noise for them, only the first one banded.
//
// Three things carry the read:
//
//  - grain. Long pale earlywood between thin dark latewood rings, the
//    rings warped and wandering the way a real trunk's are, never ruled.
//  - sheen. `m_spec_aniso`, run along the fibre direction, so the
//    highlight draws into a satin streak that travels the length of a
//    board instead of sitting as a round dot.
//  - knots. Now and then `m_cells` turns up a rare seed; near it the
//    grain is warped into a whorl around a small hard dark eye, the way
//    a real knot drags the fibres around the stub of a branch.
//
// It stays dead still: no `seconds` anywhere. Wood only moves once it is
// burning, and that is `burning_wood.fs`.

const vec3 WOOD_PALE = vec3(0.660, 0.470, 0.250); // earlywood, warm and pale
const vec3 WOOD_MID  = vec3(0.470, 0.310, 0.155); // the body between rings
const vec3 WOOD_DARK = vec3(0.270, 0.155, 0.072); // latewood, the thin dark ring
const vec3 WOOD_DEEP = vec3(0.130, 0.075, 0.038); // knot eyes and torn crevices
const vec3 WOOD_SPLINTER = vec3(0.760, 0.610, 0.380); // a raw, freshly broken fibre tip
const vec3 WOOD_SHEEN = vec3(0.980, 0.880, 0.680); // the satin streak along the grain

const float WOOD_FIBRE_X  = 0.058; // along the fibre: barely moves
const float WOOD_FIBRE_Y  = 0.88;  // across it: moves fast, so the field draws out
const float WOOD_RINGS    = 4.6;   // how many growth rings per unit of the field
const float WOOD_RING_W   = 0.16;  // how thin the dark latewood ring is
const float WOOD_RELIEF   = 1.55;  // how much the rings and fibres bump the face

const float WOOD_KNOT_SCALE  = 0.082; // a knot's territory, about 12 cells
const float WOOD_KNOT_RARITY = 0.91;  // most territories hold no knot at all
const float WOOD_KNOT_RADIUS = 5.6;   // how far a knot's whorl reaches, in cells
const float WOOD_KNOT_EYE    = 1.3;   // the hard dark centre, in cells
const float WOOD_KNOT_SWIRL  = 2.4;   // how hard the grain bends around it

const float WOOD_SHEEN_ALONG = 3.4;  // wide tolerance along the fibre: a long streak
const float WOOD_SHEEN_ACROSS = 0.30; // tight tolerance across it: a thin one

// Where the nearest knot is, if this territory holds one at all: its
// centre in cell space, how strongly this cell falls under its whorl,
// and how deep inside the hard dark eye it sits.
void wood_knot(vec2 cell, out vec2 centre, out float whorl, out float eye)
{
    vec3 f = m_cells(cell*WOOD_KNOT_SCALE);
    vec2 id = f.yz;
    centre = (id + m_hash2(id))/WOOD_KNOT_SCALE;

    float picked = step(WOOD_KNOT_RARITY, m_hash(id + 3.7));
    float dist = length(cell - centre);
    whorl = picked*smoothstep(WOOD_KNOT_RADIUS, WOOD_KNOT_RADIUS*0.12, dist);
    eye = picked*smoothstep(WOOD_KNOT_EYE, 0.0, dist);
}

// The stretched field the fibres and the rings are both cut from.
float wood_field(vec2 p)
{
    return m_fbm(vec2(p.x*WOOD_FIBRE_X, p.y*WOOD_FIBRE_Y), 5);
}

// Banding the same field into rings: fract it, and read how close each
// cell sits to a ring boundary. Close in, it is latewood; the wide gap
// between boundaries is earlywood.
float wood_rings(float field)
{
    float band = fract(field*WOOD_RINGS);
    float d = min(band, 1.0 - band);
    return 1.0 - smoothstep(0.0, WOOD_RING_W, d);
}

// The colour: earlywood and latewood banded off the field, a fine grain
// of streaks on top so no fibre is quite the same shade as its neighbour.
vec3 wood_color(vec2 p, float field, float latewood)
{
    vec3 col = mix(WOOD_PALE, WOOD_MID, smoothstep(0.30, 0.70, field));
    col = mix(col, WOOD_DARK, latewood);
    float streak = m_noise(p*3.1);
    col *= mix(0.90, 1.10, streak);
    return col;
}

// The bump: latewood rides a hair proud, earlywood sinks a hair, and a
// fine grain keeps the face from ever going glassy-smooth.
float wood_height(vec2 cell)
{
    vec2 p = vec2(cell.x*WOOD_FIBRE_X, cell.y*WOOD_FIBRE_Y);
    float field = wood_field(cell);
    float latewood = wood_rings(field);
    float fine = m_noise(p*3.1);
    return latewood*0.80 + field*0.30 + fine*0.18;
}

vec3 shade(Surf s)
{
    // A knot, if this patch of the board has one: its centre, how far
    // its whorl reaches this cell, and the hard dark eye at its middle.
    vec2 knotCentre; float whorl; float eye;
    wood_knot(s.cell, knotCentre, whorl, eye);

    // Drag the sample coordinate around the knot before anything else
    // reads it, so every field below — colour, rings, bump, sheen —
    // agrees that the grain bends here instead of running straight
    // through the branch stub.
    vec2 toKnot = s.cell - knotCentre;
    vec2 tangent = vec2(-toKnot.y, toKnot.x);
    float tlen = length(tangent);
    vec2 swirl = tlen > 0.0001 ? tangent/tlen : vec2(0.0);
    vec2 cell = s.cell + swirl*whorl*WOOD_KNOT_SWIRL;

    float field = wood_field(cell);
    float latewood = wood_rings(field);
    vec3 albedo = wood_color(cell, field, latewood);

    // The knot's own dark eye and the ring or two of tight grain right
    // around it, sunk under the whorled colour above.
    albedo = mix(albedo, WOOD_DEEP, eye*0.92);
    float knotRing = whorl*(1.0 - eye)*(0.5 + 0.5*sin(length(toKnot)*2.4));
    albedo = mix(albedo, albedo*0.72, max(knotRing, 0.0)*0.5);

    // Splintered, torn fibres where the board meets open air: pale raw
    // tips scattered along the break, with a few darker torn shreds.
    float tear = m_fbm(vec2(s.cell.x*0.05, s.cell.y*2.6) + 31.7, 3);
    float splinter = smoothstep(0.58, 0.86, tear)*s.edge;
    albedo = mix(albedo, WOOD_SPLINTER, splinter*0.55);
    float shred = smoothstep(0.62, 0.90, m_noise(s.cell*1.3 + 8.0))*s.edge;
    albedo = mix(albedo, WOOD_DEEP, shred*0.30);

    // The bump: fibre and ring relief, plus the knot rising a little
    // proud at its shoulder and sinking at its very centre.
    float e = 0.75;
    float h  = wood_height(cell);
    float hx = wood_height(cell + vec2(e, 0.0));
    float hy = wood_height(cell + vec2(0.0, e));
    vec2 slope = vec2(h - hx, h - hy)*WOOD_RELIEF;
    slope -= swirl*whorl*0.35;
    slope += normalize(toKnot + 0.001)*eye*0.55;
    s.n = normalize(vec3(s.n.xy + slope, s.n.z));

    float ndl = m_diffuse(s);
    float wrap = ndl*0.82 + 0.18; // timber never quite goes to black itself
    vec3 lit = albedo*wrap;

    // The satin streak: a highlight drawn long along the fibre and
    // pinched tight across it, the way a worked or a varnished timber
    // face throws its sheen down the length of the grain rather than as
    // a round point. The grain direction bends with the knot too.
    vec2 grainDir = normalize(vec2(1.0, 0.0) + swirl*whorl*1.4);
    float sheen = m_spec_aniso(s, grainDir, WOOD_SHEEN_ALONG, WOOD_SHEEN_ACROSS);
    lit += WOOD_SHEEN*sheen*mix(0.10, 0.30, s.ao);

    // The crevice between rings and the shoulder of a knot both sink a
    // hair under the open air's ambient occlusion.
    lit *= mix(0.62, 1.0, s.ao);

    // A warm, worn rim where the timber meets open air.
    float rim = m_fresnel(s, 2.4)*s.edge*max(dot(s.n, s.l), 0.0);
    lit += WOOD_PALE*rim*0.22;

    return m_dress(lit, s);
}
