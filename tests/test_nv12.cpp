#include <cassert>
#include <cstdio>
#include <vector>
#include "../aosp-overlay/external/v4l2_codec2/v4l2/Nv12Copy.h"
using android::h96::Plane8;
using android::h96::copyNv12;

static void layoutTest(size_t width, size_t height, int mode) {
    const size_t cw = (width + 1) / 2, ch = (height + 1) / 2;
    const size_t ys = width + 11, uvs = cw * 2 + 7;
    std::vector<uint8_t> y(ys * height, 0xee), uv(uvs * ch, 0xee);
    for (size_t r = 0; r < height; ++r)
        for (size_t c = 0; c < width; ++c) y[r * ys + c] = (r * 31 + c) % 251;
    for (size_t r = 0; r < ch; ++r)
        for (size_t c = 0; c < cw; ++c) {
            uv[r * uvs + c * 2] = (r + c * 7) % 113;
            uv[r * uvs + c * 2 + 1] = 128 + (r + c * 3) % 113;
        }
    const size_t dyStride = width + 13, dcStride = cw * 2 + 10;
    std::vector<uint8_t> dy(dyStride * height + 8, 0xcd);
    std::vector<uint8_t> dc(dcStride * ch + 8, 0xcd);
    std::vector<uint8_t> dv(dcStride * ch + 8, 0xcd);
    Plane8 dstY{dy.data(), dyStride, 1};
    Plane8 dstU{dc.data(), dcStride, mode == 2 ? 1U : 2U};
    Plane8 dstV{mode == 2 ? dv.data() : dc.data() + 1, dcStride, dstU.pixelStride};
    if (mode == 1) { dstU.data = dc.data() + 1; dstV.data = dc.data(); } // NV21
    assert(copyNv12(y.data(), y.size(), ys, uv.data(), uv.size(), uvs,
                    width, height, dstY, dstU, dstV));
    for (size_t r = 0; r < height; ++r) {
        for (size_t c = 0; c < width; ++c) assert(dy[r * dyStride + c] == y[r * ys + c]);
        for (size_t c = width; c < dyStride; ++c) assert(dy[r * dyStride + c] == 0xcd);
    }
    for (size_t r = 0; r < ch; ++r)
        for (size_t c = 0; c < cw; ++c) {
            assert(dstU.data[r * dcStride + c * dstU.pixelStride] == uv[r * uvs + c * 2]);
            assert(dstV.data[r * dcStride + c * dstV.pixelStride] == uv[r * uvs + c * 2 + 1]);
        }
    assert(dy.back() == 0xcd && dc.back() == 0xcd && dv.back() == 0xcd);
    assert(!copyNv12(y.data(), width - 1, ys, uv.data(), uv.size(), uvs,
                     width, height, dstY, dstU, dstV));
    assert(!copyNv12(y.data(), y.size(), ys, uv.data(), 1, uvs,
                     width, height, dstY, dstU, dstV));
}

int main() {
    for (int mode = 0; mode < 3; ++mode)
        for (size_t width : {1, 5, 34, 1280, 1920, 3840})
            layoutTest(width, width == 3840 ? 2160 : 17, mode);
    uint8_t p[16] = {};
    Plane8 dst{p, 4, 1};
    assert(!copyNv12(nullptr, 16, 4, p, 16, 4, 4, 4, dst, dst, dst));
    assert(!copyNv12(p, 16, 0, p, 16, 4, 4, 4, dst, dst, dst));
    assert(!copyNv12(p, 16, 4, p, 16, 4, 0, 4, dst, dst, dst));
    assert(!android::h96::validPlane(SIZE_MAX, 4, 4, 2, SIZE_MAX));
    assert(!android::h96::validPlane(4, SIZE_MAX, 4, 1, SIZE_MAX));
    std::puts("NV12: 18 layout/size cases, odd dimensions, padding, bounds/overflow: PASS");
}
