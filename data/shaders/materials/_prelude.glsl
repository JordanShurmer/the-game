#version 330

// The first part of every material shader. It declares what the game
// sets, reads the g-buffer the game fills, and works out the two things
// that make a flat grid of cells read as matter: which way the surface
// of the material faces, and where the light on it comes from.
//
// The surface normal comes from the shape of the material itself. A cell
// deep inside a body of rock faces the viewer; a cell on the rim faces
// out of the rim. The light direction comes from the light the game
// already computed: the light lies wherever the world is brighter, so
// the gradient of the light map points at it. Neither needs a uniform,
// and both follow every light in the world at once.
//
// See docs/material_shaders.md.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform vec4 colDiffuse;

uniform sampler2D gbuf;
uniform vec2 size;
uniform vec2 origin;
uniform float step_cells;
uniform float seconds;
uniform float id;
uniform float front;

out vec4 finalColor;

// What a shader is handed. Everything here is worked out once, before
// `shade` is called, so a material file holds only its own look.
struct Surf {
    vec2 cell;   // the world cell, which does not move when the camera does
    float lux;   // the light the world shades by, 0 to 1
    float glow;  // the lamp light that fell on the cell, before the response
    float sky;   // how much of the light on it is the day, 0 to 1
    float depth; // cells of the same material standing over this one
    float bury;  // 0 for a lone cell, 1 deep inside the body
    float edge;  // 1 - bury
    vec3 n;      // the way the surface faces
    vec3 l;      // the way the light comes from
    float top;   // how much the surface faces up, 0 to 1
    float ao;    // how much of the sky the cell can see, 0 to 1
};

// -------------------------------------------------------- the g-buffer

vec2 m_texel() { return 1.0/size; }

// The buffer carries the raw light in green and the part of it a lamp
// threw in alpha. The response curve is run here rather than baked into
// the buffer, so the fourth byte is free to say lamp from sky.
const float M_RESPONSE_GAMMA = 0.65;

float g_id(vec2 uv)    { return texture(gbuf, uv).r*255.0; }
float g_raw(vec2 uv)   { return texture(gbuf, uv).g; }
float g_lux(vec2 uv)   { return pow(texture(gbuf, uv).g, M_RESPONSE_GAMMA); }
float g_depth(vec2 uv) { return texture(gbuf, uv).b*255.0; }
float g_glow(vec2 uv)  { return texture(gbuf, uv).a; }

// How much of the light on a cell is the day: 0 under a lamp in a cave,
// 1 out in a field at noon.
float g_share(vec2 uv) {
    float raw = g_raw(uv);
    if (raw < 0.004) return 0.0;
    return clamp(1.0 - g_glow(uv)/raw, 0.0, 1.0);
}

// 1.0 where the cell holds the material this pass paints.
float g_same(vec2 uv) { return 1.0 - step(0.5, abs(g_id(uv) - id)); }

// ------------------------------------------------------------ the shape

const vec2 M_RING[8] = vec2[8](
    vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0),
    vec2( 0.7071,  0.7071), vec2(-0.7071,  0.7071),
    vec2( 0.7071, -0.7071), vec2(-0.7071, -0.7071));

// Look around the cell. `g` comes back pointing at the nearest edge of
// the body, longer the closer that edge is. `bury` comes back 1 where
// the whole neighbourhood holds the same material.
void m_shape(vec2 uv, out vec2 g, out float bury) {
    vec2 t = m_texel();
    g = vec2(0.0);
    float held = 0.0;
    float total = 0.0;

    for (int r = 1; r <= 3; ++r) {
        float w = 1.0/float(r);
        for (int d = 0; d < 8; ++d) {
            float s = g_same(uv + M_RING[d]*float(r)*t);
            g += M_RING[d]*(1.0 - s)*w;
            held += s*w;
            total += w;
        }
    }
    g *= 1.0/total;
    bury = held/total;
}

// The bevel. Deep inside a body the surface faces the viewer; near an
// edge it rolls over toward the open air.
vec3 m_normal(vec2 g, float roll) {
    float len = min(length(g)*roll, 1.0);
    vec2 xy = len > 0.0001 ? normalize(g)*len : vec2(0.0);
    return normalize(vec3(xy, max(1.0 - len*0.92, 0.08)));
}

// How much open air stands over the cell, which is what darkens the
// inside of a crack and leaves the crest of a boulder bright.
float m_sky(vec2 uv) {
    vec2 t = m_texel();
    float open = 0.0;
    for (int r = 1; r <= 6; ++r) {
        open += 1.0 - g_same(uv + vec2(0.0, -float(r))*t);
    }
    return open/6.0;
}

// ------------------------------------------------------------ the light

// Where the light comes from. The world is brighter toward a light, so
// the gradient of the light map points at every light there is, mixed by
// how much each one gives. Where nothing is lit it falls back to a
// standing light over the left shoulder, so a material never goes flat.
vec3 m_light(vec2 uv) {
    vec2 t = m_texel()*3.0;
    float dx = g_lux(uv + vec2(t.x, 0.0)) - g_lux(uv - vec2(t.x, 0.0));
    float dy = g_lux(uv + vec2(0.0, t.y)) - g_lux(uv - vec2(0.0, t.y));

    vec2 d = vec2(dx, dy);
    float m = length(d);
    if (m < 0.0015) return normalize(vec3(-0.42, -0.66, 0.62));
    return normalize(vec3(normalize(d)*1.35, 0.80));
}

const vec3 M_VIEW = vec3(0.0, 0.0, 1.0);

float m_diffuse(Surf s) { return max(dot(s.n, s.l), 0.0); }

float m_spec(Surf s, float gloss) {
    vec3 h = normalize(s.l + M_VIEW);
    return pow(max(dot(s.n, h), 0.0), gloss);
}

// A highlight drawn out along one axis, which is what a brushed or a
// fibrous surface gives instead of a round dot.
float m_spec_aniso(Surf s, vec2 grain, float along, float across) {
    vec3 h = normalize(s.l + M_VIEW);
    vec2 t = normalize(grain);
    vec2 b = vec2(-t.y, t.x);
    float a = dot(h.xy, t)/along;
    float c = dot(h.xy, b)/across;
    return exp(-(a*a + c*c)*4.0)*max(h.z, 0.0);
}

float m_fresnel(Surf s, float power) {
    return pow(1.0 - clamp(s.n.z, 0.0, 1.0), power);
}

// ------------------------------------------------------------- the grain

float m_hash(vec2 p) {
    p = fract(p*vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x*p.y);
}

vec2 m_hash2(vec2 p) {
    return vec2(m_hash(p), m_hash(p + 19.19));
}

float m_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f*f*(3.0 - 2.0*f);
    float a = m_hash(i);
    float b = m_hash(i + vec2(1.0, 0.0));
    float c = m_hash(i + vec2(0.0, 1.0));
    float d = m_hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float m_fbm(vec2 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; ++i) {
        sum += amp*m_noise(p);
        p = p*2.03 + vec2(17.3, 9.1);
        amp *= 0.5;
    }
    return sum;
}

// Ridged noise: the folds a rock or a metal grain leaves.
float m_ridge(vec2 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; ++i) {
        sum += amp*(1.0 - abs(m_noise(p)*2.0 - 1.0));
        p = p*2.07 + vec2(5.7, 31.1);
        amp *= 0.5;
    }
    return sum;
}

// The distance to the nearest of a scatter of points, and the point
// itself: grains, pebbles, facets, crystals.
vec3 m_cells(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float best = 8.0;
    vec2 hit = vec2(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec2 c = m_hash2(i + o);
            vec2 d = o + c - f;
            float len = dot(d, d);
            if (len < best) { best = len; hit = i + o; }
        }
    }
    return vec3(sqrt(best), hit);
}

// A hard glint that comes and goes: one grain in a scatter of them
// catches the light for a moment.
float m_glint(vec2 cell, float scale, float rate, float rarity) {
    vec3 c = m_cells(cell*scale);
    float phase = m_hash(c.yz)*6.2831;
    float pulse = sin(seconds*rate + phase)*0.5 + 0.5;
    float pick = step(rarity, m_hash(c.yz + 3.7));
    return pick*pow(pulse, 22.0)*(1.0 - smoothstep(0.0, 0.20, c.x));
}

// ---------------------------------------------------------- the finishing

// The world drew the material dark where no light reaches. A shader that
// paints its own colour must sink the same way, or an unlit cave floor
// lights up on its own.
vec3 m_gloom(vec3 col, float lux) {
    vec3 sunk = col*vec3(0.117, 0.117, 0.164) + vec3(0.012, 0.012, 0.023);
    return mix(sunk, col, lux);
}

// The haze is the light a space is full of, and a flame is what fills
// one: warm air around a lamp in a cave, strongest where the material
// it lands on is darkest.
//
// The day does not haze at all here. The sky's own colour belongs to
// air, and air is the one thing a material shader never paints -- every
// shader draws only its own cells, and no cell of air holds a material.
// So under an open sky a material comes out its own colour and nothing
// else, which is what daylight does to it. Adding the sky's colour on
// top instead put a blue fog over a whole village.
const vec3 M_HAZE = vec3(0.306, 0.251, 0.149);

vec3 m_haze(vec3 col, float lux, float sky) {
    return col + M_HAZE*(lux*(1.0 - sky))*(1.0 - col);
}

// The blow-out the world gives a cell close to a light.
const float M_BLOOM_KNEE = 0.3765;
const float M_BLOOM_STRENGTH = 0.5882;
const vec3 M_BLOOM = vec3(1.0, 0.941, 0.808);

vec3 m_bloom(vec3 col, float glow) {
    if (glow <= M_BLOOM_KNEE) return col;
    float over = (glow - M_BLOOM_KNEE)/(1.0 - M_BLOOM_KNEE)*M_BLOOM_STRENGTH;
    return mix(col, M_BLOOM, over);
}

// Light a material the way the world lights the rest of the picture, so
// a shaded cell and a flat one sit in the same air. `s.lux` is the light
// the world shades by and `s.glow` is what fell on the cell.
vec3 m_dress(vec3 albedo, Surf s) {
    return m_bloom(m_haze(m_gloom(albedo, s.lux), s.lux, s.sky), s.glow);
}
