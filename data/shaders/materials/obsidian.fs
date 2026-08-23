// Obsidian.
//
// Volcanic glass: what lava leaves when water quenches it too fast for
// any crystal to grow. It has almost no diffuse colour at all — glass
// does not scatter light inside itself, it either bounces light off the
// surface or lets it straight through. So, like a metal, nearly
// everything the eye reads here is a reflection. Unlike a metal, that
// reflection carries no tint: obsidian's F0 is a tiny, flat grey, which
// is why it looks nearly black straight on and swings, hard, into a
// near-perfect mirror at a glancing angle. That fresnel swing is the
// whole material.
//
// The other half of the read is the fracture. Glass does not chip or
// grain, it breaks in broad, smooth, curved shells — conchoidal
// fracture — so the relief here comes from a scatter of shell centres
// (`m_cells`) with a smooth dome shaded around each one, never from a
// ridged or noisy bump field. Between the shells the face stays glassy
// smooth.
//
// A very tight, hard specular sits on top of that — a small hot point,
// not a broad sheen — and deep in the body, where the glass runs thin
// enough to pass light, a faint warm brown-red glow shows through.
//
// Dead still: no `seconds` anywhere.

// Glass does not roll into a soft shoulder; it breaks at a sharp edge.
#define M_ROLL 3.0

// Nearly neutral, nudged a hair cool-violet so the body reads as black
// glass and not, once the world's warm haze lands on it, as a brown.
const vec3 OBS_F0 = vec3(0.052, 0.048, 0.062);
const vec3 OBS_WHITE = vec3(0.99, 0.99, 1.0);    // the mirror it becomes at grazing angle

// Glass breaks in broad, smooth, curved shells, and a broad shell is
// the point: small ones read as a field of bubbles, not as fracture.
const float OBS_SHELL = 0.052;    // the conchoidal shells, about 19 cells across
const float OBS_SHELL2 = 0.019;   // a second, larger family, about 53 cells
const float OBS_RELIEF = 10.0;    // how steeply a shell rolls over near its rim
const float OBS_FACET = 0.78;     // fine glassy imperfection, a cell or two — never sub-cell
const float OBS_FACET_RELIEF = 0.65;
const float OBS_ROUGH = 0.045;    // a very tight, hard, glassy speculum
const float OBS_FRESNEL_POWER = 3.0;

const vec3 OBS_GLOW = vec3(0.70, 0.22, 0.09);   // warm brown-red, the body lit from within

// Obsidian reflects about a twentieth of what falls on it head on,
// which makes it the darkest material in the world and the one that
// collects the most of the world's haze. Dressed whole it comes out
// grey, and grey glass is not glass: the fresnel swing from near black
// to near white is the entire material, and haze flattens it. So it
// gives back nearly all of the haze. See docs/material_shaders.md.
const float OBS_HAZE_EAT = 0.16;

// One conchoidal shell: the smooth dome of a curved fracture, built from
// the distance to the nearest of a scatter of shell centres. `m_cells`
// hands back that distance already normalised so a dome is just a
// smoothed fall-off from 0 at the centre. Squared, so the crown stays
// flat and glassy and all the curvature — all the slope a bump can
// give a normal — gathers at the rim, the way a real conchoidal scar
// rolls hard over near its edge and lies dead flat in the middle.
float obs_shell(vec2 p, float scale)
{
    vec3 c = m_cells(p*scale);
    float d = 1.0 - smoothstep(0.0, 0.64, c.x);
    return d*d;
}

// The macro relief: two families of curved shells laid over each other,
// one coarse and one fine, so a big conchoidal scar carries a smaller
// one nested in it the way real fracture does. No grit, no ridge noise
// — glass has neither.
float obs_shells(vec2 c)
{
    return obs_shell(c, OBS_SHELL2)*0.85 + obs_shell(c, OBS_SHELL)*0.55;
}

// A fine wash of glassy imperfection, a cell or two across, for the
// scattered micro-facets that catch the tight specular as static
// points of light rather than one smooth sheen.
float obs_facet(vec2 c)
{
    return m_noise(c*OBS_FACET)*0.5 + m_noise(c*OBS_FACET*2.13 + 5.0)*0.5;
}

// The bevel of the vein with the shells laid over it as a bump. This is
// the smooth, macro normal: the broad curve of a conchoidal shell alone,
// with nothing fine enough to trouble it, so the crown of every dome
// stays glassy and the surface between shells stays flat.
vec3 obs_macro(Surf s)
{
    float e = 0.85;
    float hs  = obs_shells(s.cell);
    float hsx = obs_shells(s.cell + vec2(e, 0.0));
    float hsy = obs_shells(s.cell + vec2(0.0, e));

    vec2 slope = vec2(hs - hsx, hs - hsy)*OBS_RELIEF;
    return normalize(vec3(s.n.xy + slope, s.n.z));
}

// The macro normal with a fine wash of glassy imperfection laid over it
// besides — used only where a hard, small specular hot point is
// computed, so the sparkle of a facet catching the light never disturbs
// the broad, clean shading of the shell itself.
vec3 obs_detail(vec3 macro, Surf s)
{
    float e = 0.85;
    float hf  = obs_facet(s.cell);
    float hfx = obs_facet(s.cell + vec2(e, 0.0));
    float hfy = obs_facet(s.cell + vec2(0.0, e));

    vec2 slope = vec2(hf - hfx, hf - hfy)*OBS_FACET_RELIEF;
    return normalize(vec3(macro.xy + slope, macro.z));
}

// A GGX-shaped lobe, tight enough to read as a hard, small hot point
// rather than a broad sheen.
float obs_spec(vec3 n, vec3 h, float rough)
{
    float a = rough*rough;
    float ndh = max(dot(n, h), 0.0);
    float d = ndh*ndh*(a*a - 1.0) + 1.0;
    return (a*a)/(3.14159265*d*d);
}

vec3 shade(Surf s)
{
    vec3 n = obs_macro(s);
    vec3 nd = obs_detail(n, s);
    vec3 h = normalize(s.l + M_VIEW);
    float ndv = max(dot(n, M_VIEW), 0.0);
    float ndl = max(dot(nd, s.l), 0.0);

    // The fresnel swing: almost nothing head on, a near-perfect,
    // uncoloured mirror at a glancing angle. This carries the material.
    vec3 fresnel = OBS_F0 + (OBS_WHITE - OBS_F0)*pow(1.0 - max(dot(h, M_VIEW), 0.0), 5.0);
    float rim = pow(1.0 - ndv, OBS_FRESNEL_POWER);
    vec3 mirror = mix(OBS_F0, OBS_WHITE, rim);

    // The lamp, reflected as a tight, hard hot point off the fine facet
    // normal, so the highlight breaks into scattered points of light
    // rather than one smooth sheen.
    float lobe = obs_spec(nd, h, OBS_ROUGH);
    float shadow = ndl/(ndl*0.6 + 0.4);
    vec3 lamp = fresnel*lobe*shadow*1.3;

    // The room, reflected: bright toward the light, almost black away
    // from it, because a mirror shows whatever it is turned toward. The
    // mirror colour itself already carries the fresnel swing, so the
    // rims of every shell go bright and the flat crowns stay near-black.
    // A shell that turns toward the lit half of the cave shows it, and
    // a shell turned away shows the dark half. In a flat world there is
    // no room to reflect, so the swing is drawn from the shell normal
    // against the light instead — but it has to be a hard swing. Shade
    // it gently and the glass goes dead black and stops reading as
    // glass at all; this sweep across the shells is what says the
    // surface is polished rather than merely dark.
    float toward = dot(n, s.l)*0.5 + 0.5;
    float sweep = pow(toward, 2.4);
    float sky = mix(0.35, 1.0, s.ao);
    vec3 env = mix(mirror*0.10, mix(mirror, OBS_WHITE, 0.45), sweep)*sky;

    // The rolled edge of a fractured lump goes wide and pale, the way a
    // shard of glass catches the light along its broken lip.
    vec3 edgeGlow = OBS_WHITE*pow(1.0 - ndv, 3.0)*0.30*s.edge;

    // Deep inside the body, thin obsidian passes a little of the light
    // that already falls on it: a faint warm brown-red glow, strongest
    // where the glass is buried and faces the viewer square on (the
    // thickest path out) and gone wherever nothing lights the cell —
    // it is transmitted light, not light the glass makes for itself.
    float inner = s.bury*(1.0 - rim);
    vec3 glow = OBS_GLOW*inner*inner*0.10*s.lux;

    vec3 col = lamp + env + edgeGlow + glow;

    vec3 dressed = m_gloom(col, s.lux);
    dressed += OBS_HAZE_EAT*vec3(0.306, 0.251, 0.149)*s.lux*(1.0 - dressed);
    return m_bloom(dressed, s.glow);
}
