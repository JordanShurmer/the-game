// The last part of every material shader. It throws away every fragment
// the material does not hold, fills the `Surf` the material reads, and
// calls the one procedure the material file brings.
//
// A brush material is drawn twice: the whole crop under the wizard,
// and then, after his sprite, the front share of it again over him, so
// he walks through the standing crop rather than in front of it. The
// `front` uniform says which pass this is. Which stalks stand in front
// is decided by world column, two cells to a stalk, so a stalk is
// wholly in front or wholly behind and the crop reads as depth rather
// than as noise. The share leans behind, so he is veiled, not hidden.

// How hard a material rolls its surface over at an edge. A material file
// may name its own before this; metal rolls hard, powder rolls soft.
#ifndef M_ROLL
#define M_ROLL 1.6
#endif

const float M_FRONT_SHARE = 0.45;

float m_front(vec2 cell) {
    return step(m_hash(vec2(floor(cell.x/2.0), 41.7)), M_FRONT_SHARE);
}

void main()
{
    vec2 uv = fragTexCoord;
    if (g_same(uv) < 0.5) discard;

    vec2 cell = origin + uv*size*step_cells;
    if (front > 0.5 && m_front(cell) < 0.5) discard;

    Surf s;
    s.uv = uv;
    s.cell = cell;
    s.base = texture(texture0, uv).rgb;
    s.lux = g_lux(uv);
    s.glow = g_glow(uv);
    s.sky = g_share(uv);
    s.depth = g_depth(uv);

    vec2 g;
    float bury;
    m_shape(uv, g, bury);
    s.bury = bury;
    s.edge = 1.0 - bury;
    s.n = m_normal(g, M_ROLL);
    s.l = m_light(uv);
    s.top = max(0.0, -s.n.y);
    s.ao = m_sky(uv);

    finalColor = vec4(shade(s), 1.0)*colDiffuse*fragColor;
}
