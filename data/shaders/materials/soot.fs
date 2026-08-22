// Soot.
//
// What fire leaves on the way to ash: a fractal deposit of carbon so fine
// it traps almost every ray that falls into it. Nothing in the game
// swallows light the way soot does, so this shader is built backward
// from every other material here — there is no lump, no facet, no bevel
// worth chasing, because a coat of soot has no shape of its own beyond
// whatever it settled on. What it has instead is a flocculent grain at
// about one cell, a colour so dark it barely separates from the gloom
// the world already sinks it into, and the faintest cool cast where the
// little light it does return leaks out. The only place it lifts at all
// is right on the rim, where a thin velvet fresnel says the deposit
// meets open air — everywhere else it reads as a hole in the wall, not
// a surface on it.

// Soot has no crisp edge to speak of, only a soft dusty give.
#define M_ROLL 1.0

const vec3 SOOT_BASE = vec3(0.090, 0.078, 0.059); // the flat colour it replaces
const vec3 SOOT_COOL = vec3(0.070, 0.078, 0.098); // the faint blue cast in its return
const vec3 SOOT_DEEP = vec3(0.028, 0.025, 0.022); // the flocculent grain, near black

const float SOOT_GRAIN = 1.3;  // the fine floccules, about one cell
const float SOOT_PUFF  = 0.32; // the loose clumps the floccules gather into

// The flocculent grain: a fine, clumpy texture — soot never settles into
// a smooth film, it piles up in tiny loose puffs of carbon. Two scales,
// a slow one for the puffs and a fast one for the floccules inside them.
// Each is pushed through a `smoothstep` to punch real contrast into it:
// a soft `m_noise`/`m_fbm` on its own averages toward the middle and
// never gets dark or light enough to read against a colour this close
// to black, where the world's own haze and gloom eat most of the swing
// a gentler curve would have left.
float soot_floc(vec2 c, out float puff)
{
    float p = m_fbm(c*SOOT_PUFF, 3);
    puff = smoothstep(0.34, 0.66, p);
    float fine = m_noise(c*SOOT_GRAIN)*0.65 + m_noise(c*SOOT_GRAIN*2.3 + 11.0)*0.35;
    return smoothstep(0.28, 0.72, fine);
}

// How much of the world's haze soot gives back. Everything else takes
// all of it. See the note at the end of `shade`.
const float SOOT_HAZE_EAT = 0.26;

vec3 shade(Surf s)
{
    float puff;
    float floc = soot_floc(s.cell, puff);

    // The grain swings the black a real amount so it reads as a texture
    // up close, even though the overall read stays almost featureless —
    // there is no lump or facet underneath it, only how deep the carbon
    // sits from one speck to the next, gathered into looser, larger
    // puffs on top of that.
    vec3 col = mix(SOOT_DEEP, SOOT_BASE, floc);
    col *= mix(0.68, 1.18, puff);

    // What little light returns leaks out with a cool cast, the way a
    // sooty deposit never quite reads warm even under a warm lamp.
    float ndl = m_diffuse(s);
    col = mix(col, SOOT_COOL*(0.6 + floc*0.5), ndl*0.30);

    // Almost no specular at all: a hint of sheen only where the surface
    // faces the lamp square on, and never bright enough to read as wet.
    float sheen = m_spec(s, 5.0);
    col += vec3(0.05, 0.055, 0.07)*sheen*ndl*0.06;

    // A barely-there velvet rim where the deposit meets open air — the
    // one place soot lifts off true black at all.
    float rim = m_fresnel(s, 1.8)*s.edge;
    col += SOOT_COOL*rim*0.75;

    // Soot swallows even the open sky; give it almost none of the lift a
    // stony crest would get.
    col *= mix(0.80, 1.0, s.ao);

    // Soot is the one material that must not take the world's haze whole.
    //
    // `m_dress` ends in `m_haze`, which adds `HAZE*lux*(1 - col)`. That
    // term is scaled by how dark the material already is, so the darker
    // a thing the more haze it collects, and everything converges on the
    // same warm beige. Rock, at about four tenths, takes a fifth of it.
    // Soot, at under a tenth, takes nearly all of it, and the blackest
    // material in the world comes out the same colour as the air beside
    // it. The picture then reads as fog, not as a hole.
    //
    // Cutting it is not a cheat. Soot is a fractal of carbon and it is
    // the least reflective thing there is: the light bouncing between it
    // and the eye is swallowed as surely as the light that lands on it.
    // So soot dresses itself, with the haze turned down.
    vec3 out_col = m_gloom(col, s.lux);
    out_col += SOOT_HAZE_EAT*vec3(0.306, 0.251, 0.149)*s.lux*(1.0 - out_col);
    return m_bloom(out_col, s.glow);
}
