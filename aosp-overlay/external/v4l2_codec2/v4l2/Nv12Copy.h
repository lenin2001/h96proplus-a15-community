// SPDX-License-Identifier: BSD-3-Clause
#ifndef H96_NV12_COPY_H
#define H96_NV12_COPY_H

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace android::h96 {

struct Plane8 {
    uint8_t* data;
    size_t rowStride;
    size_t pixelStride;
};

inline bool validPlane(size_t width, size_t height, size_t rowStride,
                       size_t pixelStride, size_t available) {
    if (!width || !height || !rowStride || !pixelStride) return false;
    constexpr size_t max = std::numeric_limits<size_t>::max();
    if (width - 1 > (max - 1) / pixelStride) return false;
    const size_t rowBytes = (width - 1) * pixelStride + 1;
    if (rowStride < rowBytes || height - 1 > (max - rowBytes) / rowStride) return false;
    return (height - 1) * rowStride + rowBytes <= available;
}

// Destination storage is owned/validated by the mapped C2GraphicView.
// Support interleaved UV, interleaved VU and separate U/V planes.
inline bool copyNv12(const uint8_t* y, size_t ySize, size_t yStride,
                     const uint8_t* uv, size_t uvSize, size_t uvStride,
                     size_t width, size_t height, Plane8 dstY, Plane8 dstU, Plane8 dstV) {
    constexpr size_t max = std::numeric_limits<size_t>::max();
    if (!y || !uv || !dstY.data || !dstU.data || !dstV.data ||
        !width || !height || width == max || height == max) return false;
    const size_t cw = (width + 1) / 2;
    const size_t ch = (height + 1) / 2;
    if (cw > max / 2 ||
        !validPlane(width, height, yStride, 1, ySize) ||
        !validPlane(cw * 2, ch, uvStride, 1, uvSize) ||
        !validPlane(width, height, dstY.rowStride, dstY.pixelStride, max) ||
        !validPlane(cw, ch, dstU.rowStride, dstU.pixelStride, max) ||
        !validPlane(cw, ch, dstV.rowStride, dstV.pixelStride, max)) return false;
    for (size_t row = 0; row < height; ++row) {
        uint8_t* dst = dstY.data + row * dstY.rowStride;
        if (dstY.pixelStride == 1) {
            std::memcpy(dst, y + row * yStride, width);
        } else {
            for (size_t col = 0; col < width; ++col)
                dst[col * dstY.pixelStride] = y[row * yStride + col];
        }
    }
    for (size_t row = 0; row < ch; ++row) {
        const uint8_t* src = uv + row * uvStride;
        uint8_t* u = dstU.data + row * dstU.rowStride;
        uint8_t* v = dstV.data + row * dstV.rowStride;
        if (dstU.pixelStride == 2 && dstV.pixelStride == 2 &&
            dstU.rowStride == dstV.rowStride && v == u + 1) {
            std::memcpy(u, src, cw * 2);
        } else {
            for (size_t col = 0; col < cw; ++col) {
                u[col * dstU.pixelStride] = src[col * 2];
                v[col * dstV.pixelStride] = src[col * 2 + 1];
            }
        }
    }
    return true;
}
}  // namespace android::h96
#endif

// ---------------------------------------------------------------------------------------------
// h96 23.09: the capture hook lives in this existing header on purpose - a new file in this
// directory changes soong glob results and forces a ~40 min full re-analysis on the build host.
// SPDX-License-Identifier: BSD-3-Clause
//
// h96 23.09.2026: bounded, disabled-by-default capture for the VP9 corruption investigation.
//
// Question it answers: at which stage do the owner's corrupt VP9 pixels first appear?
//   (1) the V4L2 CAPTURE buffer the hardware decoded into   -> decoder / reference / canvas fault
//   (2) the client graphic buffer after h96::copyNv12()      -> copy / layout fault
//   (3) neither                                              -> scanout (HWC/DRM plane) fault
//
// Per frame it computes zlib-compatible CRC32s of the VISIBLE rectangle, defined identically for
// both stages so they can be compared directly:
//   crcY  = crc32 over the visible luma rows, width bytes each
//   crcUV = crc32 over the visible chroma rows as interleaved U,V (NV12 order), width bytes each
// A frame whose destination CRCs differ from its CAPTURE CRCs was damaged by the copy. A frame
// whose CAPTURE CRCs are absent from a reference set (the same representation decoded by libvpx
// on the host, pushed as ref.txt) was damaged by the decoder. Both conditions are decided on the
// box, so only the damaged frames are dumped, together with their geometry.
//
// Nothing here runs unless the system property debug.h96.cap is non-zero when a decode session
// starts. Bits:
//   1  per-frame CRC log (both stages) + session/flush events
//   2  dump frames flagged by the rules above (needs ref.txt for the decoder rule)
//   4  also dump the first frame after start and after each flush, as a visual anchor
// Limits: debug.h96.cap.max frame pairs (default 8, hard cap 16) and 64 MiB of dumps per process.
// Disk I/O happens on a writer thread; the decode thread only copies into a bounded queue. If the
// queue is full the dump is skipped and that is logged, never blocked on.
//
// Output: /data/local/tmp/h96cap/<pid>-<n>-{log.txt,manifest.txt,fNNNN-bsID-{cap,dst}.nv12}
// (.nv12 = packed visible Y rows then packed interleaved UV rows, no padding).

#ifndef H96_CAPTURE_H
#define H96_CAPTURE_H

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include <cutils/properties.h>
#include <log/log.h>

#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1 << 7)
#endif

namespace android::h96 {

// ---- zlib-compatible CRC32 (poly 0xEDB88320, pre/post inversion done by the caller) -------------

inline const uint32_t* crcTable() {
    static uint32_t table[256];
    static std::once_flag once;
    std::call_once(once, [] {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    });
    return table;
}

inline bool haveCrcInsn() {
#if defined(__aarch64__)
    static const bool have = (getauxval(AT_HWCAP) & HWCAP_CRC32) != 0;
    return have;
#else
    return false;
#endif
}

// Raw update (no inversion): same arithmetic as ARMv8 CRC32X/CRC32B.
inline uint32_t crcRaw(uint32_t crc, const uint8_t* p, size_t n) {
#if defined(__aarch64__)
    if (haveCrcInsn()) {
        while (n && (reinterpret_cast<uintptr_t>(p) & 7)) {
            asm(".arch_extension crc\n\tcrc32b %w0, %w0, %w1" : "+r"(crc) : "r"(*p));
            ++p; --n;
        }
        while (n >= 8) {
            uint64_t v;
            memcpy(&v, p, 8);
            asm(".arch_extension crc\n\tcrc32x %w0, %w0, %x1" : "+r"(crc) : "r"(v));
            p += 8; n -= 8;
        }
        while (n) {
            asm(".arch_extension crc\n\tcrc32b %w0, %w0, %w1" : "+r"(crc) : "r"(*p));
            ++p; --n;
        }
        return crc;
    }
#endif
    const uint32_t* t = crcTable();
    while (n--) crc = t[(crc ^ *p++) & 0xff] ^ (crc >> 8);
    return crc;
}

struct PlaneView {  // one 8-bit plane: pointer to the visible origin, strides in bytes
    const uint8_t* data = nullptr;
    size_t rowStride = 0;
    size_t pixelStride = 1;
};

// crc32 of w bytes per row, h rows (luma), zlib convention.
inline uint32_t crcLuma(const PlaneView& y, size_t w, size_t h) {
    uint32_t c = 0xFFFFFFFFu;
    std::vector<uint8_t> row;
    for (size_t r = 0; r < h; ++r) {
        const uint8_t* s = y.data + r * y.rowStride;
        if (y.pixelStride == 1) {
            c = crcRaw(c, s, w);
        } else {
            row.resize(w);
            for (size_t i = 0; i < w; ++i) row[i] = s[i * y.pixelStride];
            c = crcRaw(c, row.data(), w);
        }
    }
    return ~c;
}

// crc32 of interleaved U,V rows (cw pairs = 2*cw bytes), ch rows.
inline uint32_t crcChroma(const PlaneView& u, const PlaneView& v, size_t cw, size_t ch,
                          std::vector<uint8_t>* packedOut = nullptr) {
    uint32_t c = 0xFFFFFFFFu;
    const bool nv12 = u.pixelStride == 2 && v.pixelStride == 2 && u.rowStride == v.rowStride &&
                      v.data == u.data + 1;
    std::vector<uint8_t> row(cw * 2);
    for (size_t r = 0; r < ch; ++r) {
        const uint8_t* rowPtr;
        if (nv12) {
            rowPtr = u.data + r * u.rowStride;
        } else {
            const uint8_t* su = u.data + r * u.rowStride;
            const uint8_t* sv = v.data + r * v.rowStride;
            for (size_t i = 0; i < cw; ++i) {
                row[2 * i] = su[i * u.pixelStride];
                row[2 * i + 1] = sv[i * v.pixelStride];
            }
            rowPtr = row.data();
        }
        c = crcRaw(c, rowPtr, cw * 2);
        if (packedOut) packedOut->insert(packedOut->end(), rowPtr, rowPtr + cw * 2);
    }
    return ~c;
}

inline void packLuma(const PlaneView& y, size_t w, size_t h, std::vector<uint8_t>* out) {
    for (size_t r = 0; r < h; ++r) {
        const uint8_t* s = y.data + r * y.rowStride;
        if (y.pixelStride == 1) {
            out->insert(out->end(), s, s + w);
        } else {
            for (size_t i = 0; i < w; ++i) out->push_back(s[i * y.pixelStride]);
        }
    }
}

inline int64_t monoUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

class FrameCapture {
public:
    struct Stage {  // geometry + pointers of one stage, visible origin already applied
        PlaneView y, u, v;
    };

    ~FrameCapture() { stopWriter(); }

    // Called when a decode session (re)configures its output. Reads the properties once.
    void begin(const char* what, uint32_t codedW, uint32_t codedH, uint32_t visX, uint32_t visY,
               uint32_t visW, uint32_t visH) {
        mMode = property_get_int32("debug.h96.cap", 0);
        if (!mMode) return;
        int32_t mx = property_get_int32("debug.h96.cap.max", 8);
        mMaxDumps = mx < 0 ? 0 : (mx > 16 ? 16 : mx);
        mDstEvery = property_get_int32("debug.h96.cap.dstevery", 1);
        mVisW = visW;
        mVisH = visH;
        if (mDir.empty()) openSession();
        if (mDir.empty()) { mMode = 0; return; }
        if ((mMode & 2) && mRef.empty()) loadRef();
        mAnchorPending = (mMode & 4) != 0;
        logLine("BEGIN %s coded=%ux%u visible=%u,%u %ux%u mode=%d max=%d ref=%zu", what, codedW,
                codedH, visX, visY, visW, visH, mMode, mMaxDumps, mRef.size());
        logLine("dstevery=%d", mDstEvery);
    }

    bool on() const { return mMode != 0; }

    void noteFlush() {
        if (!mMode) return;
        mAnchorPending = (mMode & 4) != 0;
        logLine("FLUSH");
    }

    void noteEvent(const char* what) {
        if (mMode) logLine("EVENT %s", what);
    }

    // Stage 1: the CAPTURE buffer, dequeued and owned by us, CPU-visible (vb2 syncs on DQBUF).
    void source(int32_t bitstreamId, size_t bufferId, const Stage& s, const char* geo) {
        mCur = Frame{};
        mCur.seq = mSeq++;
        mCur.bitstreamId = bitstreamId;
        mCur.bufferId = bufferId;
        const int64_t t0 = monoUs();
        mCur.capY = crcLuma(s.y, mVisW, mVisH);
        mCur.capUV = crcChroma(s.u, s.v, (mVisW + 1) / 2, (mVisH + 1) / 2);
        mCur.srcUs = monoUs() - t0;
        mCur.src = s;
        mCur.geo = geo;
        mCur.valid = true;
    }

    // Stage 2: the destination graphic buffer after the copy, still mapped, not yet published.
    void destination(const Stage& d, const char* dstGeo) {
        if (!mCur.valid) return;
        const char* inRef = "-";
        bool decBad = false;
        if (!mRef.empty()) {
            const bool hit = mRef.count(key(mCur.capY, mCur.capUV)) != 0;
            inRef = hit ? "Y" : "N";
            decBad = !hit;
        }
        // The destination is uncached gralloc memory: reading it back costs ~70 ms per 1080p
        // frame (measured 23.09), more than a 30 fps frame period. debug.h96.cap.dstevery=N
        // checks it on every Nth frame and on every frame the decoder already got wrong.
        const bool checkDst = mDstEvery <= 1 || decBad || (mCur.seq % mDstEvery) == 0;
        bool copyBad = false;
        if (checkDst) {
            const int64_t t0 = monoUs();
            mCur.dstY = crcLuma(d.y, mVisW, mVisH);
            mCur.dstUV = crcChroma(d.u, d.v, (mVisW + 1) / 2, (mVisH + 1) / 2);
            mCur.dstUs = monoUs() - t0;
            copyBad = mCur.dstY != mCur.capY || mCur.dstUV != mCur.capUV;
        }
        const char* why = nullptr;
        if ((mMode & 2) && decBad) why = "decoder";
        if ((mMode & 2) && copyBad) why = decBad ? "decoder+copy" : "copy";
        if (!why && mAnchorPending) why = "anchor";
        mAnchorPending = false;

        std::string dumped = "-";
        if (why) dumped = dump(mCur, d, why, dstGeo);
        logLine("F %u bs=%d buf=%zu cap=%08x/%08x dst=%08x/%08x ref=%s copy=%s srcUs=%lld dstUs=%lld dump=%s",
                mCur.seq, mCur.bitstreamId, mCur.bufferId, mCur.capY, mCur.capUV, mCur.dstY,
                mCur.dstUV, inRef, !checkDst ? "-" : copyBad ? "BAD" : "ok", (long long)mCur.srcUs,
                (long long)mCur.dstUs, dumped.c_str());
        mCur.valid = false;
    }

private:
    struct Frame {
        bool valid = false;
        uint32_t seq = 0;
        int32_t bitstreamId = -1;
        size_t bufferId = 0;
        uint32_t capY = 0, capUV = 0, dstY = 0, dstUV = 0;
        int64_t srcUs = 0, dstUs = 0;
        Stage src;
        std::string geo;
    };
    struct Job {
        std::string path;
        std::vector<uint8_t> data;  // empty => append `text` to log/manifest
        std::string text;
        bool manifest = false;
    };

    static uint64_t key(uint32_t y, uint32_t uv) { return (uint64_t(y) << 32) | uv; }

    // The c2 service runs under a seccomp filter without mkdirat (SIGSYS kills the whole
    // service, 23.09). So the directory must be created beforehand from adb
    // (mkdir -m 777 /data/local/tmp/h96cap) and each session writes prefixed files into it.
    void openSession() {
        const char* root = "/data/local/tmp/h96cap";
        if (access(root, W_OK) != 0) {
            ALOGE("h96cap: %s missing or not writable; create it from adb first", root);
            return;
        }
        static int n = 0;
        char prefix[128];
        snprintf(prefix, sizeof(prefix), "%s/%d-%d-", root, getpid(), ++n);
        mDir = prefix;
        ALOGI("h96cap: capture ON, writing %s*", prefix);
        startWriter();
    }

    void loadRef() {
        FILE* f = fopen("/data/local/tmp/h96cap/ref.txt", "r");
        if (!f) return;
        unsigned y, uv;
        char line[128];
        while (fgets(line, sizeof(line), f)) {
            if (sscanf(line, "%x %x", &y, &uv) == 2) mRef.insert(key(y, uv));
        }
        fclose(f);
    }

    std::string dump(const Frame& fr, const Stage& d, const char* why, const char* dstGeo) {
        constexpr size_t kMaxBytes = 64u << 20;
        const size_t frameBytes = size_t(mVisW) * mVisH * 3 / 2;
        if (mDumps >= mMaxDumps) return "limit";
        if (mDumpBytes + 2 * frameBytes > kMaxBytes) return "bytes";
        {
            std::lock_guard<std::mutex> l(mLock);
            if (mQueue.size() > 8) return "queue-full";
        }
        char base[256];
        snprintf(base, sizeof(base), "%sf%04u-bs%d", mDir.c_str(), fr.seq, fr.bitstreamId);
        Job cap, dst;
        cap.path = std::string(base) + "-cap.nv12";
        dst.path = std::string(base) + "-dst.nv12";
        cap.data.reserve(frameBytes);
        dst.data.reserve(frameBytes);
        packLuma(fr.src.y, mVisW, mVisH, &cap.data);
        crcChroma(fr.src.u, fr.src.v, (mVisW + 1) / 2, (mVisH + 1) / 2, &cap.data);
        packLuma(d.y, mVisW, mVisH, &dst.data);
        crcChroma(d.u, d.v, (mVisW + 1) / 2, (mVisH + 1) / 2, &dst.data);
        mDumps++;
        mDumpBytes += cap.data.size() + dst.data.size();
        Job man;
        man.manifest = true;
        char t[1024];
        snprintf(t, sizeof(t),
                 "f%04u bs=%d buf=%zu why=%s visible=%ux%u cap=%08x/%08x dst=%08x/%08x t=%lld src{%s} dst{%s}\n",
                 fr.seq, fr.bitstreamId, fr.bufferId, why, mVisW, mVisH, fr.capY, fr.capUV, fr.dstY,
                 fr.dstUV, (long long)monoUs(), fr.geo.c_str(), dstGeo);
        man.text = t;
        {
            std::lock_guard<std::mutex> l(mLock);
            mQueue.push_back(std::move(cap));
            mQueue.push_back(std::move(dst));
            mQueue.push_back(std::move(man));
        }
        mCv.notify_one();
        return why;
    }

    __attribute__((format(printf, 2, 3))) void logLine(const char* fmt, ...) {
        char buf[512];
        va_list ap;
        va_start(ap, fmt);
        int n = snprintf(buf, sizeof(buf), "%lld ", (long long)monoUs());
        vsnprintf(buf + n, sizeof(buf) - n, fmt, ap);
        va_end(ap);
        Job j;
        j.text = std::string(buf) + "\n";
        {
            std::lock_guard<std::mutex> l(mLock);
            if (mQueue.size() > 4096) return;  // never grow without bound
            mQueue.push_back(std::move(j));
        }
        mCv.notify_one();
    }

    void startWriter() {
        mStop = false;
        mWriter = std::thread([this] {
            const std::string logPath = mDir + "log.txt";
            const std::string manPath = mDir + "manifest.txt";
            for (;;) {
                Job j;
                {
                    std::unique_lock<std::mutex> l(mLock);
                    mCv.wait(l, [this] { return mStop || !mQueue.empty(); });
                    if (mQueue.empty()) return;
                    j = std::move(mQueue.front());
                    mQueue.pop_front();
                }
                const std::string& p = j.data.empty() ? (j.manifest ? manPath : logPath) : j.path;
                FILE* f = fopen(p.c_str(), j.data.empty() ? "a" : "w");
                if (!f) continue;
                if (j.data.empty())
                    fputs(j.text.c_str(), f);
                else
                    fwrite(j.data.data(), 1, j.data.size(), f);
                fclose(f);
            }
        });
    }

    void stopWriter() {
        if (!mWriter.joinable()) return;
        {
            std::lock_guard<std::mutex> l(mLock);
            mStop = true;
        }
        mCv.notify_one();
        mWriter.join();
    }

    int32_t mMode = 0;
    int32_t mMaxDumps = 8;
    int32_t mDstEvery = 1;
    uint32_t mVisW = 0, mVisH = 0;
    uint32_t mSeq = 0;
    int32_t mDumps = 0;
    size_t mDumpBytes = 0;
    bool mAnchorPending = false;
    std::string mDir;
    std::unordered_set<uint64_t> mRef;
    Frame mCur;

    std::mutex mLock;
    std::condition_variable mCv;
    std::deque<Job> mQueue;
    bool mStop = false;
    std::thread mWriter;
};

}  // namespace android::h96

#endif  // H96_CAPTURE_H
