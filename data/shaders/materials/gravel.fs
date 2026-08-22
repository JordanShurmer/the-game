// Gravel.
//
// What rock crumbles into: not a surface but a heap of broken chips,
// each one a small flat facet of the same stone `rock.fs` is cut from.
// The read has to come from the chips themselves, not from any one
// height field, because a heap has no single face to speak of — so this
// shader tiles the body into cells a few world-cells wide with `m_cells`,
// gives each one its own tilt and its own grey, and lets `m_diffuse`
// alone decide which chips catch the lamp and which sit in their own
// shadow. A soft, wide specular says these are fresh fracture faces, not
// a worn river stone. The gaps between chips carry a hard little shadow,
// because gravel is mostly gaps.

// A heap has no crisp rim: the chips at the edge roll off soft, the way
// a pile of stones does and a single boulder does not.
#define M_ROLL 1.1

const vec3 GRAVEL_BASE = vec3(0.541, 0.514, 0.467); // the flat colour it replaces
const vec3 GRAVEL_DARK = vec3(0.300, 0.284, 0.260); // a chip turned from the lamp
const vec3 GRAVEL_PALE = vec3(0.640, 0.612, 0.560); // a chip that catches it
const vec3 GRAVEL_SEAM = vec3(0.145, 0.138, 0.130); // the gap between chips

const float GRAVEL_CHIP  = 0.30;  // the chips themselves, two to five cells
const float GRAVEL_SPECK = 1.65;  // grain within a single chip
const float GRAVEL_TILT  = 0.95;  // how hard each chip cants its own way
const float GRAVEL_CRACK = 0.10;  // width of the seam between chips

// A proper faceted scatter: the nearest site (`id`, `f1`) and the second
// nearest (`f2`). `f2 - f1` is small only right at the true boundary
// between two chips, which is what lets the seam below read as a crack
// along a straight-ish edge instead of a ring around each chip's centre.
vec4 gravel_facets(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    float f1 = 8.0, f2 = 8.0;
    vec2 id = vec2(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec2 c = m_hash2(i + o);
            vec2 r = o + c - f;
            float d = dot(r, r);
            if (d < f1) { f2 = f1; f1 = d; id = i + o; }
            else if (d < f2) { f2 = d; }
        }
    }
    return vec4(sqrt(f1), id, sqrt(f2));
}

// Each chip's own facet: a per-chip random tilt laid over the g-buffer
// bevel, so the light picks out some chips and leaves others dark
// regardless of where the heap's own edge is.
vec3 gravel_facet(Surf s, vec2 chip_id)
{
    vec2 t = m_hash2(chip_id + 5.3)*2.0 - 1.0;
    return normalize(vec3(s.n.xy + t*GRAVEL_TILT, s.n.z*0.85 + 0.10));
}

vec3 shade(Surf s)
{
    vec4 chips = gravel_facets(s.cell*GRAVEL_CHIP);
    vec2 chip_id = chips.yz;
    float f1 = chips.x, f2 = chips.w;

    // Every chip is a slightly different grey, so the heap never washes
    // out as one flat tone even under even light.
    float tone = m_hash(chip_id + 1.7)*2.0 - 1.0;
    vec3 stone = GRAVEL_BASE*(1.0 + tone*0.22);
    stone = mix(stone, GRAVEL_PALE, smoothstep(0.6, 0.85, tone*0.5 + 0.5)*0.35);

    // A fine speck within the face of a chip, quartz and iron the same
    // as the rock it came from.
    float speck = m_noise(s.cell*GRAVEL_SPECK)*0.5 + m_noise(s.cell*GRAVEL_SPECK*2.2)*0.25;
    stone = mix(stone, GRAVEL_PALE, smoothstep(0.6, 0.9, speck)*0.15);
    stone = mix(stone, GRAVEL_DARK, smoothstep(0.15, 0.0, speck)*0.10);

    // The facet: each chip cants its own way, so shade with that instead
    // of the smooth bevel the g-buffer alone would give a solid body.
    vec3 n = gravel_facet(s, chip_id);
    float ndl = max(dot(n, s.l), 0.0);
    float wrap = ndl*0.85 + 0.08; // chips can go nearly dark, unlike a wall
    vec3 lit = stone*wrap;

    // The crack between two chips: hard and narrow, right on the true
    // boundary, not a halo around each chip's middle.
    float crack = 1.0 - smoothstep(0.0, GRAVEL_CRACK, f2 - f1);
    lit = mix(lit, GRAVEL_SEAM, crack*0.8);

    // A weak, wide sheen where a fresh fracture face happens to catch the
    // lamp square-on — not a wet gleam, just a hint the break is new.
    float gloss = mix(8.0, 13.0, m_hash(chip_id + 9.1));
    float sheen = m_spec(s, gloss)*(1.0 - crack);
    lit += vec3(0.9, 0.92, 0.95)*sheen*0.14;

    // Open sky picks out the crest of the heap; a shut-in crevice sinks.
    lit *= mix(0.58, 1.0, s.ao);

    return m_dress(lit, s);
}
