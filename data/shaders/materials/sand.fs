// Sand.
//
// Not a clod material like dirt: sand is countless separate glassy
// grains, each too small to shade on its own, so the body reads soft and
// matte almost everywhere. What gives it away is the rare grain that
// happens to face the lamp square on and throws back a hard, near-white
// point of light — quartz catching the sun. A heap of sand also carries
// the wind that piled it: shallow ripples, tens of cells apart, that lie
// still in world space and rake the light as it sweeps across a dune.
//
// Powder, so it slumps: the edge rolls over soft, and light wraps far
// past the terminator the way it does in any loose, pale material — a
// grain in the shadow of its neighbour still catches bounced light from
// the grains around it.

// Powder rolls its edge soft. Sand a touch firmer than dirt: the grains
// are small and hard, even if the heap as a whole slumps.
#define M_ROLL 0.95

const vec3 SAND_LIGHT = vec3(0.867, 0.749, 0.549); // sunlit dune crest
const vec3 SAND_MID   = vec3(0.737, 0.616, 0.443); // the base body colour
const vec3 SAND_DAMP  = vec3(0.471, 0.400, 0.310); // patches of damper sand
const vec3 SAND_DARK  = vec3(0.204, 0.176, 0.153); // rare heavy-mineral grains
const vec3 SAND_GLINT = vec3(1.000, 0.980, 0.930); // a grain of quartz, lit square

const float SAND_PATCH  = 0.020; // the slow colour drift, tens of cells
const float SAND_GRAIN  = 1.05;  // the grains themselves, about one cell
const float SAND_RIPPLE = 0.052; // the wind ripples, ten to thirty cells

// The wind ripples: bands that stay put in world space and wander a
// little along their own length, the way a dune's ridges do. A touch of
// the second harmonic makes the crest sharper than the trough, the way
// a real ripple's windward and leeward faces differ.
float sand_ripple(vec2 c)
{
    vec2 p = c*SAND_RIPPLE;
    // rotate the ripple direction a little so it isn't axis-aligned
    vec2 axis = vec2(0.94, 0.34);
    vec2 across = vec2(-axis.y, axis.x);
    float along = dot(p, axis);
    float bow = dot(p, across);
    float wander = m_fbm(vec2(bow*0.5, 0.0), 2)*3.2;
    float phase = (along + wander)*6.2831853;
    float ridge = sin(phase) + 0.32*sin(phase*2.0 + 0.9);
    return ridge*0.5 + 0.5;
}

// The patchwork of drier and damper sand, tens of cells wide.
vec3 sand_patch_color(vec2 c)
{
    float p = m_fbm(c*SAND_PATCH, 3);
    vec3 col = mix(SAND_MID, SAND_LIGHT, smoothstep(0.35, 0.75, p));

    float damp = m_fbm(c*SAND_PATCH*1.7 + 50.0, 2);
    return mix(col, SAND_DAMP, smoothstep(0.62, 0.86, damp)*0.6);
}

vec3 shade(Surf s)
{
    // The wind-ripple relief bumps the normal a little, so a dune's
    // crests catch the lamp and its troughs fall into their own soft
    // shade even under a flat light.
    float e = 1.4;
    float h  = sand_ripple(s.cell);
    float hx = sand_ripple(s.cell + vec2(e, 0.0));
    float hy = sand_ripple(s.cell + vec2(0.0, e));
    vec2 slope = vec2(h - hx, h - hy)*0.85;
    vec3 n = normalize(vec3(s.n.xy + slope, s.n.z));

    vec3 body = sand_patch_color(s.cell);

    // The ripple also tones the sand itself a shade paler on the crest
    // and a shade darker in the trough, the way windblown grain sorts
    // itself and catches dust in the lee. This is what keeps the bands
    // reading even where the light itself is blown out.
    body *= mix(0.90, 1.07, h);

    // A scatter of dark heavy-mineral grains, one cell or so, rare.
    vec3 gp = m_cells(s.cell*SAND_GRAIN*1.3 + 90.0);
    float mineral = smoothstep(0.20, 0.0, gp.x)*step(0.93, m_hash(gp.yz + 4.0));
    body = mix(body, SAND_DARK, mineral*0.8);

    // Fine grain texture at the size of a cell: a little brightness
    // jitter per grain so the body never looks like a flat wash.
    vec3 gr = m_cells(s.cell*SAND_GRAIN);
    float jitter = (m_hash(gr.yz) - 0.5)*0.10;
    body *= 1.0 + jitter;

    // Strong wrap diffuse: powder has no hard shadow line, light bleeds
    // far past the terminator into the heap.
    float ndl = max(dot(n, s.l), 0.0);
    float wrap = dot(n, s.l)*0.5 + 0.5;
    wrap = mix(wrap, ndl, 0.15);

    float crown = mix(0.85, 1.10, s.top);
    float shadow = mix(0.62, 1.0, s.ao);

    vec3 lit = body*wrap*crown*shadow;

    // The quartz glints: a sparse scatter of whole grains, about a cell
    // apart, that catch the lamp square on and burn hard, near-white.
    // One grain in thirty is picked; of those, only the ones facing the
    // lamp actually light up, so the scatter that shows is sparser
    // still and never the same two grains at once from one light to the
    // next disc.
    vec3 qp = m_cells(s.cell*SAND_GRAIN + 5.0);
    float spot = pow(clamp(1.0 - qp.x/0.55, 0.0, 1.0), 4.0);
    float pick = step(0.965, m_hash(qp.yz + 17.0));
    float face = max(dot(n, s.l), 0.0);
    float glint = clamp(spot*pick*pow(face, 3.0)*1.6, 0.0, 1.0);

    vec3 col = mix(lit, SAND_GLINT, glint);
    return m_dress(col, s);
}
