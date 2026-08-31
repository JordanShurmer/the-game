// The water. Eight colours and no blending: one ramp, a four by four
// ordered dither between its steps, chunky pixels, and a clock that
// ticks a few times a second. The world is a grid of coloured cells
// already, and this draws its water like one.
//
// Every number between the two tuning marks below is set by hand in the
// water lab -- `web/water-lab/index.html`, Plate VI -- where sliders
// write this block and compile it as they move, and the file is copied
// back here whole. `docs/water_lab.md` says how that works and
// `docs/water.md` says what the pass is given and what it does with it.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

uniform sampler2D mask;
uniform vec2 size;
uniform vec2 origin;
uniform float step_cells;
uniform float seconds;

out vec4 finalColor;

// >>> tuning
// The ramp, dark to light. The middle of it is the Water row of
// data/materials.txt.
const vec3 RAMP[8] = vec3[8](
    vec3(0.024, 0.051, 0.094),
    vec3(0.059, 0.118, 0.200),
    vec3(0.106, 0.208, 0.314),
    vec3(0.173, 0.322, 0.451),
    vec3(0.290, 0.498, 0.639),
    vec3(0.498, 0.702, 0.812),
    vec3(0.651, 0.776, 1.000),
    vec3(0.275, 0.643, 0.780));

const float PIX = 4.0;         // screen units to one drawn pixel
const float FPS = 24.0;        // frames a second; 0 runs the clock smooth
const float DITHER = 1.6;      // how much of the 4x4 threshold is spent
const float TOP = 4.3;         // the step of the ramp the surface sits on
const float FALL = 0.075;      // steps of ramp a cell of depth costs
const float SWELL = 0.85;      // how far the scrolling bands move the step
const float BAND = 0.15;       // how tall one band is
const float RUSH = 1.3;        // how fast the bands scroll
const float GLOOM = 4.5;       // steps the ramp drops where nothing is lit
const float LINE = 0.0;        // cells of surface drawn as the bright line
const float SPARK = 0.02;      // the share of pixels that catch the light
// <<< tuning

const float BAYER[16] = float[16](
    0.0000, 0.5000, 0.1250, 0.6250,
    0.7500, 0.2500, 0.8750, 0.3750,
    0.1875, 0.6875, 0.0625, 0.5625,
    0.9375, 0.4375, 0.8125, 0.3125);

float d_hash(vec2 p)
{
    p = fract(p*vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x*p.y);
}

void main()
{
    float code = texture(mask, fragTexCoord).r*255.0;
    if (code < 0.5) discard;

    float depth = code - 1.0;
    vec2 cell = origin + fragTexCoord*size*step_cells;

    vec3 here = texture(texture0, fragTexCoord).rgb;
    float bright = max(max(here.r, here.g), here.b);
    float lit = 1.0 - exp(-bright*3.0);

    vec2 pix = floor(cell/PIX);                          // the pixel it is in
    float tick = max(FPS, 1.0);
    float t = FPS > 0.5 ? floor(seconds*FPS)/FPS : seconds;   // and its frame

    // The bands that scroll: the whole of a sprite sheet's water in one
    // line. Two of them, at odds, so the pattern does not repeat soon.
    float band = 0.55*sin(pix.y*BAND - t*RUSH + pix.x*0.11)
               + 0.45*sin(pix.x*BAND*0.38 + t*RUSH*0.55);

    // Depth walks down the ramp; the light walks it back up.
    float level = TOP - depth*FALL + band*SWELL - (1.0 - lit)*GLOOM;

    // The dither: the fraction between two steps of the ramp is spent on
    // a threshold pattern instead of a blend.
    int bx = int(mod(pix.x, 4.0));
    int by = int(mod(pix.y, 4.0));
    float thr = (BAYER[by*4 + bx] - 0.5)*DITHER + 0.5;
    int idx = int(clamp(floor(level + thr), 0.0, 7.0));

    vec3 col = RAMP[idx];

    // The surface is a bright line broken into runs that shift on every
    // frame, which is how a sprite sheet says "water".
    if (depth < LINE) {
        float run = d_hash(vec2(floor(pix.x*0.5), floor(t*tick)*0.13));
        col = run > 0.42 ? RAMP[6] : RAMP[5];
        if (run > 0.93) col = RAMP[7];
        col *= mix(0.35, 1.0, lit);
    }

    // A sparkle: one pixel, one frame, and gone.
    float spark = d_hash(pix + floor(t*tick)*7.31);
    if (spark > 1.0 - SPARK && lit > 0.25 && depth < 26.0) col = RAMP[7];

    finalColor = vec4(col, 1.0)*colDiffuse*fragColor;
}
