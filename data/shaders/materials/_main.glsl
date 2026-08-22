// The last part of every material shader. It throws away every fragment
// the material does not hold, fills the `Surf` the material reads, and
// calls the one procedure the material file brings.

// How hard a material rolls its surface over at an edge. A material file
// may name its own before this; metal rolls hard, powder rolls soft.
#ifndef M_ROLL
#define M_ROLL 1.6
#endif

void main()
{
    vec2 uv = fragTexCoord;
    if (g_same(uv) < 0.5) discard;

    Surf s;
    s.uv = uv;
    s.cell = origin + uv*size*step_cells;
    s.base = texture(texture0, uv).rgb;
    s.lux = g_lux(uv);
    s.glow = g_glow(uv);
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
