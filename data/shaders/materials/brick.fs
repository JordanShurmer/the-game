// Brick.
//
// The one built material in the homelands, and the only thing there
// that is laid rather than grown or heaped. Everything here follows
// from that: a wall of brick is a lattice a mason set, so the shader
// draws a lattice, in world cells, in running bond -- every course
// offset half a brick from the one under it, which is what stops the
// joints lining up into a grid the eye reads as a texture rather than
// as a wall.
//
// Three things carry the read:
//
//  - the bond. A brick is BRICK_W by BRICK_H cells with a joint
//    BRICK_JOINT wide around it. The joint is paler, rougher and sunk,
//    so light rakes across the courses and every brick has a shadow
//    under its own top arris.
//  - the firing. Each brick carries its own tone off the kiln, from
//    pale sand-red through the common red to a dark overburnt end, and
//    a slow patch on top of that so a wall is not a chequerboard of
//    independent bricks either.
//  - the wear. Where the wall meets open air the arrises chip, the
//    clay under the fired skin shows through paler, and the joint
//    crumbles back to its own grit.
//
// It stays dead still: no `seconds` anywhere. A wall does not move.

// A built face: a crisp arris, not a rolled shoulder.
#define M_ROLL 2.0

const vec3 BRICK_RED   = vec3(0.472, 0.226, 0.148); // the common brick
const vec3 BRICK_PALE  = vec3(0.610, 0.372, 0.246); // an underfired, sandy one
const vec3 BRICK_BURNT = vec3(0.250, 0.118, 0.090); // an overburnt, near-purple one
const vec3 BRICK_MORTAR= vec3(0.560, 0.530, 0.470); // lime mortar in the joint
const vec3 BRICK_CLAY  = vec3(0.660, 0.430, 0.300); // raw clay under a chipped skin

const float BRICK_W = 17.0;  // cells along one brick, joint included
const float BRICK_H = 8.0;   // cells down one course, joint included
const float BRICK_JOINT = 1.6; // cells of mortar between them
const float BRICK_RELIEF = 1.9; // how much the joint sinks the light

// Where in the bond this cell lies: the brick it belongs to, and how
// far into the joint around that brick it is (0 in the face of a brick,
// 1 in the middle of a joint).
void brick_bond(vec2 cell, out vec2 id, out float joint)
{
    float course = floor(cell.y/BRICK_H);
    // Running bond: every other course starts half a brick along.
    float shift = mod(course, 2.0)*0.5*BRICK_W;
    // And a course wanders a little, because a hand laid wall does.
    shift += (m_hash(vec2(course, 3.0)) - 0.5)*2.2;

    float along = (cell.x + shift)/BRICK_W;
    id = vec2(floor(along), course);

    vec2 within = vec2(fract(along)*BRICK_W, cell.y - course*BRICK_H);
    vec2 edge = min(within, vec2(BRICK_W, BRICK_H) - within);
    float d = min(edge.x, edge.y);
    joint = 1.0 - smoothstep(0.0, BRICK_JOINT, d);
}

// The colour off the kiln for one brick, and a slow mottle over the
// whole wall so neighbours share a family.
vec3 brick_tone(vec2 id, vec2 cell)
{
    float fire = m_hash(id + 1.7);
    vec3 col = mix(BRICK_PALE, BRICK_RED, smoothstep(0.10, 0.55, fire));
    col = mix(col, BRICK_BURNT, smoothstep(0.72, 0.98, fire));

    float mottle = m_fbm(cell*0.020, 2);
    col *= mix(0.88, 1.12, mottle);

    // The face of a brick is not flat colour: a fine sand grain in it.
    col *= 1.0 + (m_noise(cell*1.9 + id*7.3) - 0.5)*0.16;
    return col;
}

// The joint stands proud of nothing: it is struck back, so it sinks,
// and the arris of the brick over it catches the light.
float brick_height(vec2 cell)
{
    vec2 id; float joint;
    brick_bond(cell, id, joint);
    float face = 1.0 - joint;
    return face*0.9 + m_noise(cell*2.3)*0.10;
}

vec3 shade(Surf s)
{
    vec2 id; float joint;
    brick_bond(s.cell, id, joint);

    vec3 albedo = brick_tone(id, s.cell);

    // The mortar: paler, rougher, gritty, and never quite one colour.
    vec3 mortar = BRICK_MORTAR*mix(0.80, 1.15, m_noise(s.cell*2.7 + 40.0));
    albedo = mix(albedo, mortar, joint*0.92);

    // Chipped arrises where the wall meets open air: the fired skin is
    // gone and the paler clay behind it shows.
    float chip = smoothstep(0.55, 0.90, m_noise(s.cell*0.9 + 13.0))*s.edge;
    albedo = mix(albedo, BRICK_CLAY, chip*0.45);

    // The bond bumps the face, so every course throws a line of shadow.
    float e = 0.8;
    float h  = brick_height(s.cell);
    float hx = brick_height(s.cell + vec2(e, 0.0));
    float hy = brick_height(s.cell + vec2(0.0, e));
    vec2 slope = vec2(h - hx, h - hy)*BRICK_RELIEF;
    s.n = normalize(vec3(s.n.xy + slope, s.n.z));

    float ndl = m_diffuse(s);
    vec3 lit = albedo*(ndl*0.86 + 0.14);

    // A joint is a crack, and a crack is dark whatever the light does.
    lit *= mix(1.0, 0.66, joint);
    lit *= mix(0.66, 1.0, s.ao);

    // Fired clay has a very slight sheen, on the face and not in the
    // joint, and it is broad rather than sharp.
    lit += vec3(0.90, 0.80, 0.70)*m_spec(s, 9.0)*(1.0 - joint)*0.07;

    return m_dress(lit, s);
}
