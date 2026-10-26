#ifndef slic3r_Utils_ColorSpaceConvert_hpp_
#define slic3r_Utils_ColorSpaceConvert_hpp_
#include <algorithm>
#include <cmath>
#include <string>
const int CUSTOM_COLOR_COUNT = 16;

#include <tuple>

std::tuple<int, int, int> rgb_to_yuv(float r, float g, float b);
double PivotRGB(double n);
double PivotXYZ(double n);
void XYZ2RGB(float X, float Y, float Z, float* R, float* G, float* B);
void Lab2XYZ(float L, float a, float b, float* X, float* Y, float* Z);
void Lab2RGB(float L, float a, float b, float* R, float* G, float* B);
void RGB2XYZ(float R, float G, float B, float* X, float* Y, float* Z);
void XYZ2Lab(float X, float Y, float Z, float* L, float* a, float* b);
void RGB2Lab(float R, float G, float B, float* L, float* a, float* b);
// The input r, g, b values should be in range [0, 1]. The output h is in range [0, 360], s is in range [0, 1] and v is in range [0, 1].
inline void RGB2HSV(float r, float g, float b, float* h, float* s, float* v)
{
    float Cmax = std::max(std::max(r, g), b);
    float Cmin = std::min(std::min(r, g), b);
    float delta = Cmax - Cmin;

    if (std::abs(delta) < 0.001f) {
        *h = 0.f;
    } else if (Cmax == r) {
        *h = 60.f * fmod((g - b) / delta, 6.f);
    } else if (Cmax == g) {
        *h = 60.f * ((b - r) / delta + 2);
    } else {
        *h = 60.f * ((r - g) / delta + 4);
    }

    if (std::abs(Cmax) < 0.001f) {
        *s = 0.f;
    } else {
        *s = delta / Cmax;
    }

    *v = Cmax;
}

float DeltaE00(float l1, float a1, float b1, float l2, float a2, float b2);
float DeltaE94(float l1, float a1, float b1, float l2, float a2, float b2);
float DeltaE76(float l1, float a1, float b1, float l2, float a2, float b2);

class wxColour;
std::string color_to_string(const wxColour &color);
wxColour    string_to_wxColor(const std::string &str);
#endif /* slic3r_Utils_ColorSpaceConvert_hpp_ */
