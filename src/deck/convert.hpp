#pragma once
#include <cstddef>
#include <cstdint>

namespace deckusb {
// Convert tightly packed BGR0 to limited-range BT.709 NV12. Dimensions must be
// positive and even; buffers must not overlap. The caller validates their sizes.
// Coefficients use 14 fractional bits (219/255 luma, 224/255 chroma). Chroma
// averages each 2x2 block before rounding, so no temporary planes are needed.
// Keep this boundary so GCC retains the no-alias inputs for loop vectorization.
__attribute__((noinline)) inline void bgr0ToNV12(const uint8_t* __restrict src,
    uint8_t* __restrict dst, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        auto in = src + y * width * 4; auto out = dst + y * width;
        for (size_t x = 0; x < width; ++x)
            out[x] = uint8_t(((2991 * in[4*x+2] + 10064 * in[4*x+1] +
                1016 * in[4*x] + 8192) >> 14) + 16);
    }
    for (size_t y = 0; y < height; y += 2) {
        auto a = src + y * width * 4; auto b = a + width * 4;
        auto out = dst + width * height + (y/2) * width;
        for (size_t x = 0; x < width; x += 2) {
            int r = a[4*x+2] + a[4*x+6] + b[4*x+2] + b[4*x+6];
            int g = a[4*x+1] + a[4*x+5] + b[4*x+1] + b[4*x+5];
            int blue = a[4*x] + a[4*x+4] + b[4*x] + b[4*x+4];
            out[x] = uint8_t(((-1649*r - 5547*g + 7196*blue + 32768) >> 16) + 128);
            out[x+1] = uint8_t(((7196*r - 6536*g - 660*blue + 32768) >> 16) + 128);
        }
    }
}
}
