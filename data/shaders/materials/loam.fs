// Loam.
//
// Tilled earth. It is the same stuff as `dirt.fs` and it must not read
// as the same stuff, because the whole point of a ploughed field is
// that a man turned it and the ground beside it is untouched. So this
// shader is dirt with three differences, and nothing else:
//
//  - it is darker and redder, because turned and manured ground holds
//    water and rots what is dug into it;
//  - the clods are bigger and they lie in ranks, not at random: a
//    plough leaves a furrow slice, and the slices lie over one another
//    all one way down the field. LOAM_FURROW is how far apart they are
//    and it is the single strongest thing in the file;
//  - chaff. Straw, root and stubble turned in with the soil and still
//    showing at the surface, which no untouched ground has.
//
// Powder, so no crisp arris: it rolls off soft, as dirt does.

#define M_ROLL 0.82

const vec3 LOAM_DARK  = vec3(0.208, 0.132, 0.078); // the turned slice, damp
const vec3 LOAM_MID   = vec3(0.315, 0.208, 0.118); // the crown of a clod, drying
const vec3 LOAM_PALE  = vec3(0.430, 0.318, 0.196); // ground the sun has had
const vec3 LOAM_HUMUS = vec3(0.076, 0.055, 0.040); // near-black rot in the furrow
const vec3 LOAM_CHAFF = vec3(0.560, 0.470, 0.270); // straw turned in with it
const vec3 LOAM_GRIT  = vec3(0.520, 0.480, 0.420); // the odd stone

const float LOAM_FURROW = 0.72; // the ranks the plough left, about 9 cells
const float LOAM_CLOD   = 0.34; // the clods, three or four cells across
const float LOAM_PATCH  = 0.024;
const float LOAM_RELIEF = 1.30;

// The ranks. A furrow slice is a long ridge with a trough beside it, so
// this is a banded field and not a scatter -- the one thing that says
// ploughed rather than heaped. The band wanders, because no furrow is
// ruled and a field of straight lines reads as a fence.
float loam_furrow(vec2 cell)
{
    float across = cell.x*LOAM_FURROW + m_fbm(cell*0.05, 2)*2.6;
    float band = fract(across);
    return 1.0 - abs(band*2.0 - 1.0);
}

// The clods on top of the ranks: bigger than dirt's, and squashed along
// the furrow because that is the way the share dragged them.
float loam_height(vec2 cell)
{
    vec3 h = m_cells(cell*vec2(LOAM_CLOD, LOAM_CLOD*0.62));
    float dome = 1.0 - smoothstep(0.0, 0.72, h.x);
    return loam_furrow(cell)*0.85 + dome*dome*0.55 + m_noise(cell*2.0)*0.10;
}

vec3 loam_color(vec2 cell, float ridge)
{
    float patch = m_fbm(cell*LOAM_PATCH, 2);
    patch = clamp((patch - 0.5)*2.2 + 0.5, 0.0, 1.0);
    vec3 col = mix(LOAM_DARK, LOAM_MID, smoothstep(0.28, 0.72, patch));
    col = mix(col, LOAM_PALE, smoothstep(0.70, 0.95, patch)*0.7);

    // The crown of a slice dries out pale; the trough beside it stays
    // wet and nearly black.
    col = mix(LOAM_HUMUS, col, smoothstep(0.06, 0.55, ridge));
    return col;
}

vec3 shade(Surf s)
{
    float ridge = loam_furrow(s.cell);
    vec3 albedo = loam_color(s.cell, ridge);

    // Each clod a shade off its neighbours.
    vec3 hp = m_cells(s.cell*vec2(LOAM_CLOD, LOAM_CLOD*0.62));
    albedo *= 1.0 + (m_hash(hp.yz)*2.0 - 1.0)*0.11;

    // Chaff and stubble turned in, and the odd stone the plough struck.
    vec3 fleck = m_cells(s.cell*1.5);
    float pick = m_hash(fleck.yz + 9.1);
    float near = smoothstep(0.26, 0.0, fleck.x);
    albedo = mix(albedo, LOAM_CHAFF, near*step(0.88, pick)*0.8);
    albedo = mix(albedo, LOAM_GRIT, near*step(0.975, pick + 0.01));

    float e = 0.9;
    float h  = loam_height(s.cell);
    float hx = loam_height(s.cell + vec2(e, 0.0));
    float hy = loam_height(s.cell + vec2(0.0, e));
    s.n = normalize(vec3(s.n.xy + vec2(h - hx, h - hy)*LOAM_RELIEF, s.n.z));

    // Earth has no mirror in it. A soft wrap so a clod never goes fully
    // black on its own shadow side.
    float ndl = max(dot(s.n, s.l), 0.0);
    vec3 lit = albedo*(ndl*0.72 + 0.28);

    lit *= mix(0.90, 1.14, s.top);
    lit *= mix(0.55, 1.0, s.ao);

    // Wet turned soil holds a faint damp sheen in the trough, where the
    // water sits, and none at all on a dried crown.
    float damp = clamp(s.bury*(1.0 - ridge), 0.0, 1.0);
    lit += vec3(0.20, 0.17, 0.13)*m_spec(s, 18.0)*damp*0.35;

    return m_dress(lit, s);
}
