#version 330

// The wave that bends what lies under the water is the wave of the
// raylib example shader examples/shaders/resources/shaders/glsl330/wave.fs,
// contributed by Anata (@anatagawa) and reviewed by Ramon Santamaria
// (@raysan5), which ships with raylib under the zlib licence. The rest of
// this file is the game's own. docs/water.md says what was taken, what was
// added, and which other shaders were read before this one was written.

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

const float WAVE_FREQ_X = 0.21;
const float WAVE_FREQ_Y = 0.17;
const float WAVE_AMP_X = 1.7;
const float WAVE_AMP_Y = 1.1;
const float WAVE_SPEED_X = 1.4;
const float WAVE_SPEED_Y = 1.1;

const float SINK = 0.07;
const vec3 DEEP = vec3(0.55, 0.78, 1.06);

const vec3 GLINT = vec3(0.60, 0.86, 1.00);
const float CAUSTIC_SCALE = 0.16;    // net cells about six world cells wide
const float CAUSTIC_LIGHT = 0.55;
const float CAUSTIC_SOFT = 0.32;     // how wide the bright bands blur
const float CAUSTIC_FALL = 0.06;     // the net dims as the light spreads
const float SURFACE_LIGHT = 0.36;
const float SURFACE_FALL = 0.9;
const float LIT_GAIN = 3.0;

const float MIRROR = 0.34;           // how much of the world above shows
const float MIRROR_FALL = 0.030;     // and how fast depth swallows it
const float MIRROR_WOBBLE = 1.1;     // cells of sideways shimmer

float w_hash(vec2 p)
{
    p = fract(p*vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x*p.y);
}

// The net light leaves on the bottom of a pond is the boundary of a
// pattern of cells: bright curved seams where neighbouring lenses of
// surface meet, dark inside each lens. So it is drawn from a scatter of
// points that drift, as the distance to the *seam* between the nearest
// point and the next: zero on the seam, and the seam glows.
float w_seam(vec2 p, float t)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    float f1 = 8.0;
    float f2 = 8.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec2 h = vec2(w_hash(i + o), w_hash(i + o + 19.19));
            vec2 c = o + 0.5 + 0.38*sin(t + 6.2831*h) - f;
            float d = dot(c, c);
            if (d < f1) { f2 = f1; f1 = d; }
            else if (d < f2) { f2 = d; }
        }
    }
    return sqrt(f2) - sqrt(f1);
}

float caustic(vec2 cell, float t)
{
    vec2 p = cell*CAUSTIC_SCALE;
    float a = w_seam(p, t*0.6);
    float b = w_seam(p*1.83 + 7.7, -t*0.45);
    float net = smoothstep(CAUSTIC_SOFT, 0.0, a)*0.75
              + smoothstep(CAUSTIC_SOFT*1.4, 0.0, b)*0.45;
    return net*net;
}

void main()
{
    float code = texture(mask, fragTexCoord).r*255.0;
    if (code < 0.5) discard;

    float depth = code - 1.0;
    vec2 texel = 1.0/size;
    vec2 cell = origin + fragTexCoord*size*step_cells;

    vec2 p = fragTexCoord;
    p.x += cos(cell.y*WAVE_FREQ_X + seconds*WAVE_SPEED_X)*WAVE_AMP_X*texel.x;
    p.y += sin(cell.x*WAVE_FREQ_Y + seconds*WAVE_SPEED_Y)*WAVE_AMP_Y*texel.y;

    vec3 under = texture(texture0, p).rgb;
    vec3 here = texture(texture0, fragTexCoord).rgb;

    float bright = max(max(here.r, here.g), here.b);
    float lit = 1.0 - exp(-bright*LIT_GAIN);
    lit *= lit;

    // The glint takes the colour of the light that made it: green under
    // the fireflies, warm under the orb, and the blue of the water when
    // neither is near.
    vec3 glint = mix(GLINT, here/max(bright, 0.001), 0.45);
    float sink = 1.0 - exp(-depth*SINK);
    float top = exp(-depth*SURFACE_FALL);

    vec3 col = under*mix(vec3(1.0), DEEP, sink);

    // The world above the surface, mirrored into it. The sample is of the
    // picture the light already drew, so a dark shore stays a dark shore;
    // what this brings the pond is the firefly and the orb, upside down
    // and wavering, which is what still water does at night.
    float up = depth/step_cells;
    float wob = sin(cell.y*0.9 + seconds*1.3)
              + 0.6*sin(cell.x*0.23 - seconds*0.8);
    vec2 above = fragTexCoord + vec2(
        wob*MIRROR_WOBBLE/step_cells*texel.x,
        -2.0*up*texel.y);
    vec3 sky = texture(texture0, clamp(above, vec2(0.0), vec2(1.0))).rgb;
    col += sky*MIRROR*exp(-depth*MIRROR_FALL);

    // The caustic net on what lies under, and the shimmer at the surface.
    // Both are scaled by the light the CPU already gave the texel, so the
    // shader brightens no water the world left dark.
    float ripple = 0.6 + 0.4*sin(cell.x*0.5 - seconds*2.6)
                       *sin(cell.x*0.13 + seconds*0.7);

    // A few points of the surface catch the light and let it go: each
    // two-cell run has its own phase, and the pow keeps all but the
    // crest of each pulse dark, so the line twinkles instead of glowing.
    float wink = pow(0.5 + 0.5*sin(seconds*2.3 + 6.2831*w_hash(
        vec2(floor(cell.x*0.5), 3.7))), 18.0);

    col += glint*lit*(caustic(cell, seconds)*CAUSTIC_LIGHT
                          *mix(0.22, 1.0, exp(-depth*CAUSTIC_FALL))
                      + top*(ripple*SURFACE_LIGHT + wink*0.55));

    finalColor = vec4(col, 1.0)*colDiffuse*fragColor;
}
