// Ash.
//
// What is left when soot itself finishes burning: dry, pale, weightless
// powder. Where soot is a hole that traps light, ash is the opposite —
// a heap of flakes so fine and so many-faced that light entering it
// bounces from flake to flake before it escapes, so the whole heap
// glows a little even away from the lamp. That is a wrap-around diffuse,
// not a rolled bevel: `dot(n,l)` is remapped so the terminator itself
// goes soft and light bleeds around it, which is the one thing that
// makes a powder read as a powder instead of a chalky rock. The edge
// rolls the softest of any material here, the flakes are fine at one to
// two cells, and a few unburnt cinders sit through it, darker and never
// quite consumed.

// The softest rolled edge in the game: ash has no shoulder at all, only
// a fading drift into whatever it is heaped against.
#define M_ROLL 0.85

const vec3 ASH_BASE   = vec3(0.686, 0.686, 0.627); // the flat colour it replaces
const vec3 ASH_PALE   = vec3(0.760, 0.756, 0.700); // a flake caught full in the light
const vec3 ASH_DARK   = vec3(0.520, 0.512, 0.470); // a flake turned from it
const vec3 ASH_CINDER = vec3(0.185, 0.168, 0.150); // an unburnt fleck, never consumed

const float ASH_FLAKE  = 1.15; // the flakes themselves, one to two cells
const float ASH_DRIFT  = 0.065; // a slow drift in how thick the ash lies
const float ASH_CINDER_RATE = 0.06; // how much of the heap is still cinder

// The flakes: fine, soft-edged, never a hard facet. Two close scales so
// no single flake reads as a repeating tile, each pushed through a
// `smoothstep` — a bare `m_noise` sits too close to the middle of its
// range to separate one flake from the next against a colour this pale,
// where the world's own haze flattens a gentle curve almost flat.
float ash_flake(vec2 c)
{
    float a = smoothstep(0.32, 0.68, m_noise(c*ASH_FLAKE));
    float b = smoothstep(0.32, 0.68, m_noise(c*ASH_FLAKE*2.15 + 6.0));
    return a*0.6 + b*0.4;
}

// A dark unburnt cinder, scattered thin through the powder.
float ash_cinder(vec2 c, out vec2 id)
{
    vec3 h = m_cells(c*0.85 + 31.0);
    id = h.yz;
    return h.x;
}

vec3 shade(Surf s)
{
    // A slow drift in how thick the ash lies, so a heap is not one flat
    // grey from crest to crest.
    float drift = m_fbm(s.cell*ASH_DRIFT, 3);
    vec3 powder = mix(ASH_DARK, ASH_BASE, smoothstep(0.30, 0.70, drift));

    // The flakes themselves, fine and soft.
    float flake = ash_flake(s.cell);
    powder = mix(powder, ASH_PALE, flake*0.55);
    powder = mix(powder, ASH_DARK, (1.0 - flake)*0.40);

    // A few cinders never finished burning: small dark flecks sitting
    // through the powder, sparse and irregular.
    vec2 cinder_id;
    float cinder_d = ash_cinder(s.cell, cinder_id);
    float cinder_here = step(1.0 - ASH_CINDER_RATE, m_hash(cinder_id + 2.3));
    float cinder_near = smoothstep(0.36, 0.0, cinder_d);
    powder = mix(powder, ASH_CINDER, cinder_near*cinder_here*0.9);

    // The wrap-around diffuse: light bleeds around the terminator the
    // way it does through a heap of tiny scattering flakes, so the dark
    // side of a mound never reads as a hard shadow the way a solid body
    // would. This single remap is what makes ash read as powder.
    float wrap = max(dot(s.n, s.l)*0.5 + 0.5, 0.0);
    vec3 lit = powder*(wrap*0.85 + 0.15);

    // The crown of a heap catches a hair more light, standing clear of
    // the sky above it; a shut-in crevice sinks, but never far — ash
    // never really goes dark on itself the way a denser powder would.
    float crown = mix(0.92, 1.10, s.top);
    float shadow = mix(0.78, 1.0, s.ao);
    lit *= crown*shadow;

    // Almost no sheen: a bare hint where a flake happens to lie flat to
    // the lamp, dust-dry rather than a gleam.
    float sheen = m_spec(s, 3.0);
    lit += vec3(1.0, 0.98, 0.94)*sheen*0.04;

    return m_dress(lit, s);
}
