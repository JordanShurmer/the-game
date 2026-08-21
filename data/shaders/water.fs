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

const float SINK = 0.055;
const vec3 DEEP = vec3(0.55, 0.78, 1.06);

const vec3 GLINT = vec3(0.60, 0.86, 1.00);
const float CAUSTIC_SHARP = 9.0;
const float CAUSTIC_WARP = 4.5;
const float CAUSTIC_LIGHT = 0.62;
const float SURFACE_LIGHT = 0.50;
const float SURFACE_FALL = 0.9;
const float RIPPLE_FREQ = 0.5;
const float RIPPLE_SPEED = 2.6;
const float LIT_GAIN = 3.2;

float ridge(float wave)
{
    return pow(1.0 - abs(wave)*0.5, CAUSTIC_SHARP);
}

float caustic(vec2 cell, float t)
{
    vec2 warp = cell + vec2(sin(cell.y*0.11 + t*0.70), cos(cell.x*0.09 - t*0.60))*CAUSTIC_WARP;

    float a = sin(warp.x*0.31 + t*1.3) + sin(warp.y*0.23 - t*0.9);
    float b = sin((warp.x + warp.y)*0.19 - t*1.7) + sin((warp.x - warp.y)*0.13 + t*1.1);
    return max(ridge(a), ridge(b));
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

    float lit = clamp(max(max(here.r, here.g), here.b)*LIT_GAIN, 0.0, 1.0);
    float sink = 1.0 - exp(-depth*SINK);
    float top = exp(-depth*SURFACE_FALL);
    float ripple = 0.5 + 0.5*sin(cell.x*RIPPLE_FREQ - seconds*RIPPLE_SPEED);

    vec3 col = under*mix(vec3(1.0), DEEP, sink);
    col += GLINT*lit*(caustic(cell, seconds)*CAUSTIC_LIGHT*(0.35 + 0.65*top) + top*ripple*SURFACE_LIGHT);

    finalColor = vec4(col, 1.0)*colDiffuse*fragColor;
}
