// Fire.
//
// Fire is not a surface, it is a volume of burning gas, so almost
// nothing here comes from the shape helpers a solid material leans on.
// `s.n` goes unused — there is no face to shade, no specular to throw
// — and nothing is dressed: fire makes its own light and gives none of
// it back to the dark the way a lit rock would, so `m_dress` never
// runs here at all.
//
// What does the work instead is `s.depth`. Fire rises, so a tongue of
// it stands base-down: the cell at the foot of a flame has many cells
// of fire standing over it and reads a high `depth`, while a lick at
// the very top has nothing above it and reads near zero. That alone
// gives the base-to-tip gradient — white and hottest low, cooling
// through yellow, orange and red as `depth` falls away to nothing.
//
// Everything else is turbulence: three layers of noise scrolling
// upward against `seconds`, each at its own frequency and speed so the
// flame never reads as one sliding texture, broken into ridged fingers
// so the edge of a tongue licks rather than blurs. The one deliberate
// colour lie is the rim: real or not, a thread of blue-violet right at
// the thinnest, hottest edge is what makes gas read as flame instead
// of paint.

const vec3 FIRE_WHITE  = vec3(1.000, 0.975, 0.900);
const vec3 FIRE_YELLOW = vec3(1.000, 0.820, 0.240);
const vec3 FIRE_ORANGE = vec3(1.000, 0.420, 0.055);
const vec3 FIRE_RED    = vec3(0.620, 0.070, 0.020);
const vec3 FIRE_DARK   = vec3(0.050, 0.010, 0.014); // the smoky, near-spent tip
const vec3 FIRE_VIOLET = vec3(0.560, 0.360, 1.000);  // the hottest, thinnest edge

const float FIRE_TALL    = 15.0;  // cells of depth a flame needs to run hot
const float FIRE_RISE_A  = 1.9;   // scroll speed, the coarse licks
const float FIRE_RISE_B  = 3.4;   // scroll speed, the fine tearing
const float FIRE_RISE_C  = 0.9;   // scroll speed, the slow drift beneath both

// The blackbody ramp fire cools along as it climbs: white at its
// hottest, down to a dying red, then out into the dark of spent gas.
// `h` is heat, 0 to 1.
vec3 fire_ramp(float h)
{
    h = clamp(h, 0.0, 1.0);
    vec3 col = FIRE_DARK;
    col = mix(col, FIRE_RED, smoothstep(0.06, 0.32, h));
    col = mix(col, FIRE_ORANGE, smoothstep(0.28, 0.58, h));
    col = mix(col, FIRE_YELLOW, smoothstep(0.55, 0.82, h));
    col = mix(col, FIRE_WHITE, smoothstep(0.80, 1.0, h));
    return col;
}

vec3 shade(Surf s)
{
    // Three layers of noise, each scrolling up at its own speed and
    // its own scale, so the turbulence never reads as one texture
    // sliding by. `-y` is up in cell space.
    vec2 c = s.cell;
    float licksA = m_fbm(vec2(c.x*0.16, c.y*0.20 - seconds*FIRE_RISE_A), 4);
    float licksB = m_fbm(vec2(c.x*0.34, c.y*0.46 - seconds*FIRE_RISE_B) + 30.0, 3);
    float drift  = m_fbm(vec2(c.x*0.06, c.y*0.08 - seconds*FIRE_RISE_C) + 70.0, 3);

    // Ridged noise folds the turbulence into fingers, which is what
    // breaks a flame's edge into tongues instead of a soft blur.
    float ridge = m_ridge(vec2(c.x*0.15, c.y*0.24 - seconds*FIRE_RISE_A*1.15) + 12.0, 3);

    float turb = licksA*0.42 + licksB*0.23 + drift*0.20 + ridge*0.30 - 0.50;

    // Fire rises base-down, so the cell count standing over this one
    // finds the foot of the flame: many cells above means this is
    // low and hot, none above means this is the tip and cooling fast.
    float base = 1.0 - exp(-s.depth/FIRE_TALL);

    // A lick curling right at the top of its reach catches an instant
    // brighter before it gives out.
    float crown = s.top*(1.0 - base)*0.18;

    // A thin, lone cell or the wandering vein has no room to build a
    // tall body of flame, so it burns mostly off its own edge instead
    // of off a settled base beneath it.
    float lone = s.edge*(1.0 - base)*0.30;

    // The foot of a flame is hotter than its tip, but the foot is not
    // one flat white sheet: a body of fire is torn through by its own
    // turbulence at every height. So the depth only biases the heat,
    // and the noise carries it. Weight it the other way round and a
    // slab of fire saturates to a wall of white below its first two
    // dozen cells.
    float heat = clamp(base*0.55 + turb*1.05 + crown + lone, 0.0, 1.0);

    // The turbulence also eats into the body itself: where it runs
    // low, the gas thins to nothing rather than staying a solid block.
    float body = smoothstep(-0.32, 0.05, turb + base*0.55 - 0.20);

    vec3 col = fire_ramp(heat)*body;

    // The very edge of a tongue, where it burns thinnest, carries a
    // thread of blue-violet ahead of the orange. Small, and only where
    // the gas is both hot and about to give out.
    float rim = smoothstep(0.55, 0.95, s.edge)*smoothstep(0.35, 0.85, heat)*body;
    col = mix(col, FIRE_VIOLET, rim*0.30);

    return col;
}
