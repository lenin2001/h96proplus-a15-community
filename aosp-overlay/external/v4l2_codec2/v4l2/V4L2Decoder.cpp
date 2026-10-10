// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

//#define LOG_NDEBUG 0
#define ATRACE_TAG ATRACE_TAG_VIDEO
#define LOG_TAG "V4L2Decoder"

#include <v4l2_codec2/v4l2/V4L2Decoder.h>

#include <stdint.h>
#include <string.h>

#include <algorithm>
#include <vector>

#include <base/bind.h>
#include <base/files/scoped_file.h>
#include <base/memory/ptr_util.h>
#include <log/log.h>
#include <utils/Trace.h>

#include <C2Buffer.h>
#include <v4l2_codec2/common/Common.h>
#include <v4l2_codec2/common/Fourcc.h>
#include <v4l2_codec2/common/H264NalParser.h>
#include <v4l2_codec2/common/HEVCNalParser.h>
#include <v4l2_codec2/plugin_store/DmabufHelpers.h>

#include "Nv12Copy.h"

namespace android {
namespace {

// Extra buffers for transmitting in the whole video pipeline.
constexpr size_t kNumExtraOutputBuffers = 4;
constexpr size_t kMaxReadyClientFrames = 3;

bool waitForDRC(const C2ConstLinearBlock& input, std::optional<VideoCodec> codec) {
    C2ReadView view = input.map().get();
    const uint8_t* pos = view.data();
    // frame type takes the (2) position in first byte of VP9  uncompressed header
    const uint8_t kVP9FrameTypeMask = 0x4;
    // frame type takes the (0) position in first byte of VP8 uncompressed header
    const uint8_t kVP8FrameTypeMask = 0x1;

    switch (*codec) {
    case VideoCodec::H264: {
        H264NalParser parser(view.data(), view.capacity());
        return parser.locateIDR();
    }
    case VideoCodec::HEVC: {
        HEVCNalParser parser(view.data(), view.capacity());
        return parser.locateIDR();
    }
    // For VP8 and VP9 it is assumed that the input buffer contains a single
    // frame that is not fragmented.
    case VideoCodec::VP9:
        // 0 - key frame; 1 - interframe
        return ((pos[0] & kVP9FrameTypeMask) == 0);
    case VideoCodec::VP8:
        // 0 - key frame; 1 - interframe;
        return ((pos[0] & kVP8FrameTypeMask) == 0);
    }

    return false;
}

}  // namespace

// static
std::unique_ptr<VideoDecoder> V4L2Decoder::Create(
        uint32_t debugStreamId, const VideoCodec& codec, const size_t inputBufferSize,
        const size_t minNumOutputBuffers, GetPoolCB getPoolCb, OutputCB outputCb, ErrorCB errorCb,
        scoped_refptr<::base::SequencedTaskRunner> taskRunner, bool isSecure) {
    std::unique_ptr<V4L2Decoder> decoder =
            ::base::WrapUnique<V4L2Decoder>(new V4L2Decoder(debugStreamId, taskRunner));
    if (!decoder->start(codec, inputBufferSize, minNumOutputBuffers, std::move(getPoolCb),
                        std::move(outputCb), std::move(errorCb), isSecure)) {
        return nullptr;
    }
    return decoder;
}

V4L2Decoder::V4L2Decoder(uint32_t debugStreamId,
                         scoped_refptr<::base::SequencedTaskRunner> taskRunner)
      : mDebugStreamId(debugStreamId), mTaskRunner(std::move(taskRunner)) {
    ALOGV("%s()", __func__);

    mWeakThis = mWeakThisFactory.GetWeakPtr();
}

V4L2Decoder::~V4L2Decoder() {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    mWeakThisFactory.InvalidateWeakPtrs();

    // Streamoff input and output queue.
    if (mOutputQueue) {
        mOutputQueue->streamoff();
        mOutputQueue->deallocateBuffers();
        mOutputQueue = nullptr;
    }
    if (mInputQueue) {
        mInputQueue->streamoff();
        mInputQueue->deallocateBuffers();
        mInputQueue = nullptr;
    }
    if (mDevice) {
        mDevice->stopPolling();
        mDevice = nullptr;
    }
    if (mInitialEosBuffer) {
        mInitialEosBuffer = nullptr;
    }
}

bool V4L2Decoder::start(const VideoCodec& codec, const size_t inputBufferSize,
                        const size_t minNumOutputBuffers, GetPoolCB getPoolCb, OutputCB outputCb,
                        ErrorCB errorCb, bool isSecure) {
    ATRACE_CALL();
    ALOGV("%s(codec=%s, inputBufferSize=%zu, minNumOutputBuffers=%zu)", __func__,
          VideoCodecToString(codec), inputBufferSize, minNumOutputBuffers);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    mMinNumOutputBuffers = minNumOutputBuffers;
    mGetPoolCb = std::move(getPoolCb);
    mOutputCb = std::move(outputCb);
    mErrorCb = std::move(errorCb);
    mCodec = codec;
    mIsSecure = isSecure;
    // The MMAP bridge must never map protected content on the CPU.
    if (isSecure) {
        ALOGE("Protected playback is not supported by the H96 MMAP bridge.");
        return false;
    }

    if (mState == State::Error) {
        ALOGE("Ignore due to error state.");
        return false;
    }

    mDevice = V4L2Device::create(mDebugStreamId);

    const uint32_t inputPixelFormat = V4L2Device::videoCodecToPixFmt(codec);
    if (!mDevice->open(V4L2Device::Type::kDecoder, inputPixelFormat)) {
        ALOGE("Failed to open device for %s", VideoCodecToString(codec));
        return false;
    }

    if (!mDevice->hasCapabilities(V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_STREAMING)) {
        ALOGE("Device does not have VIDEO_M2M_MPLANE and STREAMING capabilities.");
        return false;
    }

    if (!sendV4L2DecoderCmd(false)) {
        ALOGE("Device does not support flushing (V4L2_DEC_CMD_STOP)");
        return false;
    }

    // Subscribe to the resolution change event.
    struct v4l2_event_subscription sub;
    memset(&sub, 0, sizeof(sub));
    sub.type = V4L2_EVENT_SOURCE_CHANGE;
    if (mDevice->ioctl(VIDIOC_SUBSCRIBE_EVENT, &sub) != 0) {
        ALOGE("ioctl() failed: VIDIOC_SUBSCRIBE_EVENT: V4L2_EVENT_SOURCE_CHANGE");
        return false;
    }

    // Create Input/Output V4L2Queue, and setup input queue.
    mInputQueue = mDevice->getQueue(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE);
    mOutputQueue = mDevice->getQueue(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE);
    if (!mInputQueue || !mOutputQueue) {
        ALOGE("Failed to create V4L2 queue.");
        return false;
    }
    if (!setupInputFormat(inputPixelFormat, inputBufferSize)) {
        ALOGE("Failed to setup input format.");
        return false;
    }
    if (!setupInitialOutput()) {
        ALOGE("Unable to setup initial output");
        return false;
    }

    if (!mDevice->startPolling(mTaskRunner,
                               ::base::BindRepeating(&V4L2Decoder::serviceDeviceTask, mWeakThis),
                               ::base::BindRepeating(&V4L2Decoder::onError, mWeakThis))) {
        ALOGE("Failed to start polling V4L2 device.");
        return false;
    }

    setState(State::Idle);
    return true;
}

bool V4L2Decoder::setupInputFormat(const uint32_t inputPixelFormat, const size_t inputBufferSize) {
    ALOGV("%s(inputPixelFormat=%u, inputBufferSize=%zu)", __func__, inputPixelFormat,
          inputBufferSize);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    // Check if the format is supported.
    std::vector<uint32_t> formats =
            mDevice->enumerateSupportedPixelformats(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE);
    if (std::find(formats.begin(), formats.end(), inputPixelFormat) == formats.end()) {
        ALOGE("Input codec s not supported by device.");
        return false;
    }

    // Setup the input format.
    auto format = mInputQueue->setFormat(inputPixelFormat, ui::Size(), inputBufferSize, 0);
    if (!format) {
        ALOGE("Failed to call IOCTL to set input format.");
        return false;
    }
    ALOG_ASSERT(format->fmt.pix_mp.pixelformat == inputPixelFormat);

    /* h96: вход переведён с DMABUF на MMAP+копирование. Клиентские линейные
     * блоки C2 приходят из system dma-heap (набор страниц), а meson-vdec
     * (vb2-dma-contig + esparser) принимает только физически непрерывные
     * буферы: импорт падал в ядре с «contiguous chunk is too small
     * 1048576/2097152», VIDIOC_QBUF возвращал ошибку и декодер уходил в
     * Error. MMAP-буферы выделяет сам драйвер из CMA (512 МиБ), а битстрим
     * копируется CPU — для 2-5 МБ/с это незаметно. Ровно так же работал
     * весь наш bring-up декодера (ffmpeg v4l2m2m использует MMAP). */
    if (mInputQueue->allocateBuffers(kNumInputBuffers, V4L2_MEMORY_MMAP) == 0) {
        ALOGE("Failed to allocate input buffer.");
        return false;
    }
    if (!mInputQueue->streamon()) {
        ALOGE("Failed to streamon input queue.");
        return false;
    }
    return true;
}

bool V4L2Decoder::setupInitialOutput() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (!setupMinimalOutputFormat()) {
        ALOGE("Failed to set minimal resolution for initial output buffers");
        return false;
    }

    if (!startOutputQueue(1, V4L2_MEMORY_MMAP)) {
        ALOGE("Failed to start initialy output queue");
        return false;
    }

    std::optional<V4L2WritableBufferRef> eosBuffer = mOutputQueue->getFreeBuffer();
    if (!eosBuffer) {
        ALOGE("Failed to acquire initial EOS buffer");
        return false;
    }

    mInitialEosBuffer =
            new GraphicBuffer(mCodedSize.getWidth(), mCodedSize.getHeight(),
                              static_cast<PixelFormat>(HalPixelFormat::YCBCR_420_888),
                              GraphicBuffer::USAGE_HW_VIDEO_ENCODER, "V4L2DecodeComponent");

    if (mInitialEosBuffer->initCheck() != NO_ERROR) {
        return false;
    }

    /* h96: очередь теперь MMAP — пробный EOS-буфер ставим как MMAP,
     * GraphicBuffer нужен только чтобы объект жил (waitForDRC смотрит id). */
    if (!std::move(*eosBuffer).queueMMap()) {
        ALOGE("Failed to queue initial EOS buffer");
        return false;
    }
    if (!mOutputQueue->streamon()) {
        ALOGE("Failed to streamon initial output queue.");
        return false;
    }

    return true;
}

bool V4L2Decoder::setupMinimalOutputFormat() {
    ui::Size minResolution, maxResolution;

    for (const uint32_t& pixfmt :
         mDevice->enumerateSupportedPixelformats(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)) {
        if (pixfmt != Fourcc::NM12) {
            ALOGD("Pixel format %s is not supported, skipping...", fourccToString(pixfmt).c_str());
            continue;
        }

        mDevice->getSupportedResolution(pixfmt, &minResolution, &maxResolution);
        if (minResolution.isEmpty()) {
            minResolution.set(128, 128);
        }

        if (mOutputQueue->setFormat(pixfmt, minResolution, 0) != std::nullopt) {
            return true;
        }
    }

    ALOGE("Failed to find supported pixel format");
    return false;
}

bool V4L2Decoder::startOutputQueue(size_t minOutputBuffersCount, enum v4l2_memory memory) {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());
    if (memory != V4L2_MEMORY_MMAP) {
        ALOGE("H96 zero-copy capture is disabled pending hardware validation.");
        return false;
    }

    const std::optional<struct v4l2_format> format = getFormatInfo();
    std::optional<size_t> numOutputBuffers = getNumOutputBuffers();
    if (!format || !numOutputBuffers) {
        return false;
    }
    *numOutputBuffers = std::max(*numOutputBuffers, minOutputBuffersCount);

    // Release old mappings before REQBUFS(0) / S_FMT, including DRC frames
    // which are still waiting for a client block.
    if (mOutputQueue->allocatedBuffersCount() > 0 && !mOutputQueue->streamoff())
        return false;
    while (!mDecodedMmapFrames.empty()) mDecodedMmapFrames.pop();
    mDrainLastSeen = false;
    mDrainFailed = false;
    while (!mReadyClientFrames.empty()) mReadyClientFrames.pop();
    mFrameAtDevice.clear();
    while (!mReuseFrameQueue.empty()) mReuseFrameQueue.pop();
    mQuarantineBlocks.clear();
    mBlockIdToV4L2Id.clear();
    if (mOutputQueue->allocatedBuffersCount() > 0 &&
        !mOutputQueue->deallocateBuffers()) return false;

    const ui::Size codedSize(format->fmt.pix_mp.width, format->fmt.pix_mp.height);
    if (!setupOutputFormat(codedSize)) {
        return false;
    }

    const std::optional<struct v4l2_format> adjustedFormat = getFormatInfo();
    if (!adjustedFormat || adjustedFormat->fmt.pix_mp.pixelformat != Fourcc::NM12 ||
        adjustedFormat->fmt.pix_mp.num_planes != 2) {
        return false;
    }
    mCodedSize.set(adjustedFormat->fmt.pix_mp.width, adjustedFormat->fmt.pix_mp.height);
    mVisibleRect = getVisibleRect(mCodedSize);

    ALOGI("Need %zu output buffers. coded size: %s, visible rect: %s", *numOutputBuffers,
          toString(mCodedSize).c_str(), toString(mVisibleRect).c_str());
    if (isEmpty(mCodedSize)) {
        ALOGE("Failed to get resolution from V4L2 driver.");
        return false;
    }

    const size_t adjustedNumOutputBuffers =
            mOutputQueue->allocateBuffers(*numOutputBuffers, memory);
    if (adjustedNumOutputBuffers == 0) {
        ALOGE("Failed to allocate output buffer.");
        return false;
    }

    ALOGV("Allocated %zu output buffers.", adjustedNumOutputBuffers);

    mCaptureStride = adjustedFormat->fmt.pix_mp.plane_fmt[0].bytesperline;
    mCaptureChromaStride = adjustedFormat->fmt.pix_mp.plane_fmt[1].bytesperline;

    // h96 23.09: diagnostic capture; stays off unless debug.h96.cap is set (H96Capture.h).
    if (!mCap) mCap = std::make_unique<h96::FrameCapture>();
    mCap->begin(minOutputBuffersCount <= 1 ? "initial" : "drc", mCodedSize.width,
                mCodedSize.height, mVisibleRect.left, mVisibleRect.top, mVisibleRect.width(),
                mVisibleRect.height());

    mUseDmabufOutput = false;

    /* h96: MMAP-выход стартовой фиктивной очереди (до SOURCE_CHANGE).
     * Один буфер оставляем свободным — start() берёт его под пробный
     * EOS (waitForDRC). */
    size_t keepFree = (minOutputBuffersCount <= 1) ? 1 : 0;
    while (mOutputQueue->freeBuffersCount() > keepFree) {
        auto ob = mOutputQueue->getFreeBuffer();
        if (!ob) break;
        if (!std::move(*ob).queueMMap()) {
            ALOGE("h96: initial MMAP QBUF failed");
            return false;
        }
    }

    // All MMAP capture buffers must be queued before the driver snapshots
    // canvas addresses. Initial setup queues its final EOS slot separately.
    if (keepFree == 0 && !mOutputQueue->streamon()) {
        ALOGE("Failed to streamon populated MMAP capture queue.");
        return false;
    }
    ALOGI("h96: hardware decode, MMAP capture (%zu buffers), CPU frame copy",
          adjustedNumOutputBuffers);
    return true;
}

void V4L2Decoder::decode(std::unique_ptr<ConstBitstreamBuffer> buffer, DecodeCB decodeCb) {
    ATRACE_CALL();
    ALOGV("%s(id=%d)", __func__, buffer->id);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState == State::Error) {
        ALOGE("Ignore due to error state.");
        mTaskRunner->PostTask(FROM_HERE, ::base::BindOnce(std::move(decodeCb),
                                                          VideoDecoder::DecodeStatus::kError));
        return;
    }

    if (mState == State::Idle) {
        setState(State::Decoding);
    }

    // To determine if the DRC is pending, the access to the frame data is
    // required. It's not possible to access the frame directly for the secure
    // playback, so this check must be skipped. b/279834186
    if (!mIsSecure && mInitialEosBuffer && !mPendingDRC)
        mPendingDRC = waitForDRC(buffer->dmabuf, mCodec);

    mDecodeRequests.push(DecodeRequest(std::move(buffer), std::move(decodeCb)));
    pumpDecodeRequest();
}

void V4L2Decoder::drain(DecodeCB drainCb) {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    switch (mState) {
    case State::Idle:
        ALOGV("Nothing need to drain, ignore.");
        mTaskRunner->PostTask(
                FROM_HERE, ::base::BindOnce(std::move(drainCb), VideoDecoder::DecodeStatus::kOk));
        return;

    case State::Decoding:
        mDecodeRequests.push(DecodeRequest(nullptr, std::move(drainCb)));
        pumpDecodeRequest();
        return;

    case State::Draining:
    case State::Error:
        ALOGE("Ignore due to wrong state: %s", StateToString(mState));
        mTaskRunner->PostTask(FROM_HERE, ::base::BindOnce(std::move(drainCb),
                                                          VideoDecoder::DecodeStatus::kError));
        return;
    }
}

void V4L2Decoder::pumpDecodeRequest() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState != State::Decoding) return;

    while (!mDecodeRequests.empty()) {
        // Drain the decoder.
        if (mDecodeRequests.front().buffer == nullptr) {
            ALOGV("Get drain request.");
            // Send the flush command after all input buffers are dequeued. This makes
            // sure all previous resolution changes have been handled because the
            // driver must hold the input buffer that triggers resolution change. The
            // driver cannot decode data in it without new output buffers. If we send
            // the flush now and a queued input buffer triggers resolution change
            // later, the driver will send an output buffer that has
            // V4L2_BUF_FLAG_LAST. But some queued input buffer have not been decoded
            // yet. Also, V4L2VDA calls STREAMOFF and STREAMON after resolution
            // change. They implicitly send a V4L2_DEC_CMD_STOP and V4L2_DEC_CMD_START
            // to the decoder.
            if (mInputQueue->queuedBuffersCount() > 0) {
                ALOGV("Wait for all input buffers dequeued.");
                return;
            }

            // If output queue is not streaming, then device is unable to notify
            // whenever draining is finished. (EOS frame cannot be dequeued).
            // This is likely to happen in the event of that the first resolution
            // change event wasn't dequeued before the drain request.
            if (!mOutputQueue->isStreaming()) {
                ALOGV("Wait for output queue to start streaming");
                return;
            }

            auto request = std::move(mDecodeRequests.front());
            mDecodeRequests.pop();

            // There is one more case that EOS frame cannot be dequeued because
            // the first resolution change event wasn't dequeued before - output
            // queues on the host are not streaming but ARCVM has no knowledge about
            // it. Check if first resolution change event was received and if there
            // was no previously sent non-empty frame (other than SPS/PPS/EOS) that
            // may trigger config from host side.
            // Drain can only be finished if we are sure there was no stream = no
            // single frame in the stack.
            if (mInitialEosBuffer && !mPendingDRC) {
                ALOGV("Terminate drain, because there was no stream");
                mTaskRunner->PostTask(FROM_HERE, ::base::BindOnce(std::move(request.decodeCb),
                                                                  VideoDecoder::DecodeStatus::kOk));
                return;
            }

            if (!sendV4L2DecoderCmd(false)) {
                std::move(request.decodeCb).Run(VideoDecoder::DecodeStatus::kError);
                onError();
                return;
            }
            mDrainCb = std::move(request.decodeCb);
            mDrainLastSeen = false;
            mDrainFailed = false;
            setState(State::Draining);
            return;
        }

        // h96: для MMAP-входа переиспользование буфера по dmabuf-id не имеет
        // смысла — данные каждый раз копируются в буфер драйвера.
        std::optional<V4L2WritableBufferRef> inputBuffer = mInputQueue->getFreeBuffer();

        // Pause if no free input buffer. We resume decoding after dequeueing input buffers.
        if (!inputBuffer) {
            ALOGV("There is no free input buffer.");
            return;
        }

        auto request = std::move(mDecodeRequests.front());
        mDecodeRequests.pop();

        const int32_t bitstreamId = request.buffer->id;
        ALOGV("QBUF to input queue, bitstreadId=%d", bitstreamId);
        inputBuffer->setTimeStamp({.tv_sec = bitstreamId});
        size_t planeSize = inputBuffer->getPlaneSize(0);
        if (request.buffer->size > planeSize) {
            ALOGE("The input size (%zu) is not enough, we need %zu", planeSize,
                  request.buffer->size);
            onError();
            return;
        }

        C2ReadView view = request.buffer->dmabuf.map().get();
        if (view.error() != C2_OK) {
            ALOGE("Failed to map input block, error: %d", view.error());
            onError();
            return;
        }
        void* dst = inputBuffer->getPlaneMapping(0);
        if (dst == nullptr) {
            ALOGE("Failed to map V4L2 MMAP input buffer.");
            onError();
            return;
        }
        memcpy(dst, view.data(), request.buffer->size);
        inputBuffer->setPlaneDataOffset(0, 0);
        inputBuffer->setPlaneBytesUsed(0, request.buffer->size);
        if (!std::move(*inputBuffer).queueMMap()) {
            ALOGE("%s(): Failed to QBUF to input queue, bitstreamId=%d", __func__, bitstreamId);
            onError();
            return;
        }

        mPendingDecodeCbs.insert(std::make_pair(bitstreamId, std::move(request.decodeCb)));
    }
}

void V4L2Decoder::flush() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState == State::Idle) {
        ALOGV("Nothing need to flush, ignore.");
        return;
    }
    if (mState == State::Error) {
        ALOGE("Ignore due to error state.");
        return;
    }

    // Call all pending callbacks.
    for (auto& item : mPendingDecodeCbs) {
        std::move(item.second).Run(VideoDecoder::DecodeStatus::kAborted);
    }
    mPendingDecodeCbs.clear();
    if (mDrainCb) {
        std::move(mDrainCb).Run(VideoDecoder::DecodeStatus::kAborted);
    }
    /* h96 03.09: flush не чистил mDecodeRequests - после seek pumpDecodeRequest
     * кормил драйвер СТАРЫМИ AU, а их decodeCb приходил в DecodeComponent уже
     * после reportAbandonedWorks (разыменование end() -> падение c2-сервиса
     * на втором seek). Все ещё не скормленные запросы - kAborted. */
    while (!mDecodeRequests.empty()) {
        DecodeRequest req = std::move(mDecodeRequests.front());
        mDecodeRequests.pop();
        if (req.decodeCb) std::move(req.decodeCb).Run(VideoDecoder::DecodeStatus::kAborted);
    }
    mDrainLastSeen = false;
    mDrainFailed = false;
    if (mCap) mCap->noteFlush();

    // Streamoff both V4L2 queues to drop input and output buffers.
    const bool isOutputStreaming = mOutputQueue->isStreaming();
    mDevice->stopPolling();
    if (!mOutputQueue->streamoff()) {
        onError();
        return;
    }

    // Extract currently enqueued output picture buffers to be queued later first.
    // See b/270003218 and b/297228544.
    for (auto& [v4l2Id, frame] : mFrameAtDevice) {
        // Find corresponding mapping block ID (DMABUF ID) to V4L2 buffer ID.
        // The buffer was enqueued to device therefore such mapping have to exist.
        auto blockIdIter =
                std::find_if(mBlockIdToV4L2Id.begin(), mBlockIdToV4L2Id.end(),
                             [v4l2Id = v4l2Id](const auto& el) { return el.second == v4l2Id; });

        ALOG_ASSERT(blockIdIter != mBlockIdToV4L2Id.end());
        size_t blockId = blockIdIter->first;
        mReuseFrameQueue.push(std::make_pair(blockId, std::move(frame)));
    }
    mFrameAtDevice.clear();

    if (!mInputQueue->streamoff()) {
        onError();
        return;
    }

    // Populate CAPTURE while both queues are stopped. Starting first let
    // meson-vdec snapshot an incomplete pool (also after every seek).
    if (isOutputStreaming) {
        if (mUseDmabufOutput) {
            /* h96 zero-copy: кадры, снятые с драйвера, лежат в
             * mReuseFrameQueue — tryFetchVideoFrame() вернёт их в свои
             * слоты (карта статична, физадреса совпадут с канвасами). */
            tryFetchVideoFrame();
        } else {
            /* h96: MMAP — после streamoff все буферы свободны,
             * возвращаем полный список драйверу. */
            while (!mDecodedMmapFrames.empty())
                mDecodedMmapFrames.pop();
            while (auto ob = mOutputQueue->getFreeBuffer()) {
                if (!std::move(*ob).queueMMap()) {
                    ALOGE("h96: flush MMAP re-queue failed");
                    onError();
                    return;
                }
            }
        }
    }
    if (!mInputQueue->streamon() ||
        (isOutputStreaming && !mOutputQueue->streamon())) {
        onError();
        return;
    }

    // If there is no free buffer at mOutputQueue, tryFetchVideoFrame() should be triggerred after
    // a buffer is DQBUF from output queue. Now all the buffers are dropped at mOutputQueue, we
    // have to trigger tryFetchVideoFrame() here.
    if (mVideoFramePool) {
        tryFetchVideoFrame();
    }

    if (!mDevice->startPolling(mTaskRunner,
                               ::base::BindRepeating(&V4L2Decoder::serviceDeviceTask, mWeakThis),
                               ::base::BindRepeating(&V4L2Decoder::onError, mWeakThis))) {
        ALOGE("Failed to start polling V4L2 device.");
        onError();
        return;
    }

    setState(State::Idle);
}

void V4L2Decoder::serviceDeviceTask(bool event) {
    ATRACE_CALL();
    ALOGV("%s(event=%d) state=%s InputQueue(%s):%zu+%zu/%zu, OutputQueue(%s):%zu+%zu/%zu", __func__,
          event, StateToString(mState), (mInputQueue->isStreaming() ? "streamon" : "streamoff"),
          mInputQueue->freeBuffersCount(), mInputQueue->queuedBuffersCount(),
          mInputQueue->allocatedBuffersCount(),
          (mOutputQueue->isStreaming() ? "streamon" : "streamoff"),
          mOutputQueue->freeBuffersCount(), mOutputQueue->queuedBuffersCount(),
          mOutputQueue->allocatedBuffersCount());

    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState == State::Error) return;

    // Dequeue output and input queue.
    bool inputDequeued = false;
    while (mInputQueue->queuedBuffersCount() > 0) {
        bool success;
        V4L2ReadableBufferRef dequeuedBuffer;
        std::tie(success, dequeuedBuffer) = mInputQueue->dequeueBuffer();
        if (!success) {
            ALOGE("Failed to dequeue buffer from input queue.");
            onError();
            return;
        }
        if (!dequeuedBuffer) break;

        inputDequeued = true;

        // Run the corresponding decode callback.
        int32_t id = dequeuedBuffer->getTimeStamp().tv_sec;
        ALOGV("DQBUF from input queue, bitstreamId=%d", id);
        auto it = mPendingDecodeCbs.find(id);
        if (it == mPendingDecodeCbs.end()) {
            ALOGW("Callback is already abandoned.");
            continue;
        }
        std::move(it->second).Run(VideoDecoder::DecodeStatus::kOk);
        mPendingDecodeCbs.erase(it);
    }

    bool outputDequeued = false;
    while (mOutputQueue->queuedBuffersCount() > 0) {
        bool success;
        V4L2ReadableBufferRef dequeuedBuffer;
        std::tie(success, dequeuedBuffer) = mOutputQueue->dequeueBuffer();
        if (!success) {
            ALOGE("Failed to dequeue buffer from output queue.");
            onError();
            return;
        }
        if (!dequeuedBuffer) break;

        outputDequeued = true;

        const size_t bufferId = dequeuedBuffer->bufferId();
        const int32_t bitstreamId = static_cast<int32_t>(dequeuedBuffer->getTimeStamp().tv_sec);
        const size_t bytesUsed = dequeuedBuffer->getPlaneBytesUsed(0);
        const bool isLast = dequeuedBuffer->isLast();
        if (mDrainCb && isLast) {
            mDrainLastSeen = true;
            /* h96: LAST+ERROR = драйвер не довёл drain (таймаут) — это не
             * чистый конец потока, клиент должен получить ошибку. */
            if (dequeuedBuffer->isError()) {
                ALOGE("h96: drain ended with LAST+ERROR (bufferId=%zu)", bufferId);
                mDrainFailed = true;
            }
        }
        ALOGV("DQBUF from output queue, bufferId=%zu, bitstreamId=%d, bytesused=%zu, isLast=%d",
              bufferId, bitstreamId, bytesUsed, isLast);

        if (mUseDmabufOutput) {
            /* h96 zero-copy: кадр уже в клиентском блоке — отдаём без копии. */
            auto fIt = mFrameAtDevice.find(bufferId);
            if (fIt == mFrameAtDevice.end()) {
                ALOGE("h96: DQBUF for unknown v4l2 slot %zu", bufferId);
                onError();
                return;
            }
            std::unique_ptr<VideoFrame> frame = std::move(fIt->second);
            mFrameAtDevice.erase(fIt);
            dequeuedBuffer.reset();
            if (bytesUsed == 0) {
                auto ob = mOutputQueue->getFreeBuffer(bufferId);
                if (!ob || !std::move(*ob).queueDMABuf(frame->getFDs())) {
                    ALOGE("h96: re-queue empty DMABUF failed");
                    onError();
                    return;
                }
                mFrameAtDevice.insert_or_assign(bufferId, std::move(frame));
            } else {
                frame->setBitstreamId(bitstreamId);
                frame->setVisibleRect(mVisibleRect);
                mOutputCb.Run(std::move(frame));
                tryFetchVideoFrame();
            }
        } else if (bytesUsed == 0) {
            /* h96: MMAP — пустышка (EOS) сразу назад в очередь. */
            const size_t emptyId = bufferId;
            dequeuedBuffer.reset();
            auto ob = mOutputQueue->getFreeBuffer(emptyId);
            if (!ob || !std::move(*ob).queueMMap()) {
                ALOGE("h96: re-queue empty MMAP buffer failed");
                onError();
                return;
            }
        } else {
            // Transfer the only readable reference. Keeping a local copy
            // would prevent tryOutputDecodedFrame() from reclaiming this slot.
            mDecodedMmapFrames.push(std::move(dequeuedBuffer));
            tryOutputDecodedFrame();
            if (mReadyClientFrames.empty()) tryFetchVideoFrame();
        }

        // LAST can be an empty marker behind frames awaiting a client block.
        // Do not report EOS before those frames have reached the client.
        if (mState == State::Error) return;
        finishDrainIfReady();
        if (mState == State::Error) return;
    }

    // Handle resolution change event.
    if (event && dequeueResolutionChangeEvent()) {
        if (!changeResolution()) {
            onError();
            return;
        }
    }

    // We freed some input buffers, continue handling decode requests.
    if (inputDequeued) {
        mTaskRunner->PostTask(FROM_HERE,
                              ::base::BindOnce(&V4L2Decoder::pumpDecodeRequest, mWeakThis));
    }
    // We free some output buffers, try to get VideoFrame.
    if (outputDequeued) {
        mTaskRunner->PostTask(FROM_HERE,
                              ::base::BindOnce(&V4L2Decoder::tryFetchVideoFrame, mWeakThis));
    }
}

bool V4L2Decoder::dequeueResolutionChangeEvent() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    struct v4l2_event ev;
    memset(&ev, 0, sizeof(ev));
    while (mDevice->ioctl(VIDIOC_DQEVENT, &ev) == 0) {
        if (ev.type == V4L2_EVENT_SOURCE_CHANGE &&
            ev.u.src_change.changes & V4L2_EVENT_SRC_CH_RESOLUTION) {
            return true;
        }
    }
    return false;
}

bool V4L2Decoder::changeResolution() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mInitialEosBuffer) {
        mInitialEosBuffer = nullptr;
    }

    // Fixed driver-owned capture buffers avoid late gralloc QBUF/recycle and
    // buffer-ID churn. This remains hardware decoding, not a software codec.
    mVideoFramePool.reset();
    if (!startOutputQueue(mMinNumOutputBuffers, V4L2_MEMORY_MMAP)) {
        ALOGE("Failed to start output queue during DRC.");
        return false;
    }

    // If drain request is pending then it means that previous call to pumpDecodeRequest
    // stalled the request, bacause there was no way of notifing the component that
    // drain has finished. Send this request the drain to device.
    if (!mDecodeRequests.empty() && mDecodeRequests.front().buffer == nullptr) {
        mTaskRunner->PostTask(FROM_HERE,
                              ::base::BindOnce(&V4L2Decoder::pumpDecodeRequest, mWeakThis));
    }

    // The previous pool was released before reconfiguring the capture queue.
    // Always use flexible pixel 420 format YCBCR_420_888 in Android.
    mVideoFramePool = mGetPoolCb.Run(mCodedSize, HalPixelFormat::YCBCR_420_888,
                                     mOutputQueue->allocatedBuffersCount());
    if (!mVideoFramePool) {
        ALOGE("Failed to get block pool with size: %s", toString(mCodedSize).c_str());
        return false;
    }

    tryFetchVideoFrame();
    return true;
}

bool V4L2Decoder::setupOutputFormat(const ui::Size& size) {
    for (const uint32_t& pixfmt :
         mDevice->enumerateSupportedPixelformats(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)) {
        if (pixfmt != Fourcc::NM12) {
            ALOGD("Pixel format %s is not supported, skipping...", fourccToString(pixfmt).c_str());
            continue;
        }

        if (mOutputQueue->setFormat(pixfmt, size, 0) != std::nullopt) {
            return true;
        }
    }

    ALOGE("Failed to find supported pixel format");
    return false;
}

void V4L2Decoder::tryOutputDecodedFrame() {
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());
    if (mState == State::Error) return;

    while (!mDecodedMmapFrames.empty() && !mReadyClientFrames.empty()) {
        V4L2ReadableBufferRef src = mDecodedMmapFrames.front();
        mDecodedMmapFrames.pop();
        std::unique_ptr<VideoFrame> frame = std::move(mReadyClientFrames.front());
        mReadyClientFrames.pop();

        const int32_t bitstreamId = static_cast<int32_t>(src->getTimeStamp().tv_sec);
        const size_t srcBufferId = src->bufferId();

        // The mapping is released (and CPU writes flushed) before handing the
        // graphic block to Surface. Do not keep a C2GraphicView alive across OutputCB.
        if (!copyMmapFrame(src, frame.get())) {
            ALOGE("h96: invalid MMAP/client plane layout or mapping");
            onError();
            return;
        }

        src.reset();  /* вернуть MMAP-буфер драйверу */
        auto ob = mOutputQueue->getFreeBuffer(srcBufferId);
        if (!ob || !std::move(*ob).queueMMap()) {
            ALOGE("h96: re-queue MMAP buffer failed");
            onError();
            return;
        }

        ALOGV("h96: copied frame bitstreamId=%d to client block", bitstreamId);
        frame->setBitstreamId(bitstreamId);
        frame->setVisibleRect(mVisibleRect);
        mOutputCb.Run(std::move(frame));

        if (mState == State::Error) return;
    }
    finishDrainIfReady();
    if (mState == State::Error) return;

    /* держим небольшой запас клиентских блоков наготове */
    if (mReadyClientFrames.size() < kMaxReadyClientFrames && mVideoFramePool)
        tryFetchVideoFrame();
}

void V4L2Decoder::finishDrainIfReady() {
    if (!mDrainCb || !mDrainLastSeen || !mDecodedMmapFrames.empty() ||
        mState == State::Error) return;
    if (!sendV4L2DecoderCmd(true)) {
        onError();
        return;
    }
    const bool failed = mDrainFailed;
    mDrainLastSeen = false;
    mDrainFailed = false;
    setState(State::Idle);
    std::move(mDrainCb).Run(failed ? VideoDecoder::DecodeStatus::kError
                                   : VideoDecoder::DecodeStatus::kOk);
}

bool V4L2Decoder::copyMmapFrame(const V4L2ReadableBufferRef& src, VideoFrame* frame) {
    if (src->planesCount() != 2) return false;
    C2GraphicView view = frame->getMutableBlock()->map().get();
    if (view.error() != C2_OK || !view.data()) return false;
    const C2PlanarLayout layout = view.layout();
    const uint32_t width = mCodedSize.width;
    const uint32_t height = mCodedSize.height;
    const C2Rect crop = view.crop();
    if (layout.type != C2PlanarLayout::TYPE_YUV || layout.numPlanes != 3 ||
        crop.left != 0 || crop.top != 0 || crop.width < width || crop.height < height)
        return false;
    h96::Plane8 dst[3];
    for (unsigned int i = 0; i < 3; ++i) {
        const C2PlaneInfo& p = layout.planes[i];
        const uint32_t sampling = i == 0 ? 1 : 2;
        if (p.rowInc <= 0 || p.colInc <= 0 || p.allocatedDepth != 8 ||
            p.bitDepth != 8 || p.rightShift != 0 ||
            p.colSampling != sampling || p.rowSampling != sampling)
            return false;
        dst[i] = {view.data()[i], static_cast<size_t>(p.rowInc),
                  static_cast<size_t>(p.colInc)};
    }
    const uint8_t* y = static_cast<const uint8_t*>(src->getPlaneMapping(0));
    const uint8_t* uv = static_cast<const uint8_t*>(src->getPlaneMapping(1));
    const size_t yOffset = src->getPlaneDataOffset(0);
    const size_t uvOffset = src->getPlaneDataOffset(1);
    if (!y || !uv || yOffset > src->getPlaneSize(0) || uvOffset > src->getPlaneSize(1))
        return false;
    // h96 23.09: stage 1 of the diagnostic capture - the CAPTURE planes, dequeued and owned
    // here, before anything is copied. Off unless debug.h96.cap is set.
    const bool cap = mCap && mCap->on() && mVisibleRect.left >= 0 && mVisibleRect.top >= 0 &&
                     static_cast<uint32_t>(mVisibleRect.right) <= width &&
                     static_cast<uint32_t>(mVisibleRect.bottom) <= height;
    const size_t vx = cap ? static_cast<size_t>(mVisibleRect.left) : 0;
    const size_t vy = cap ? static_cast<size_t>(mVisibleRect.top) : 0;
    if (cap) {
        h96::FrameCapture::Stage s;
        s.y = {y + yOffset + vy * mCaptureStride + vx, mCaptureStride, 1};
        const uint8_t* c = uv + uvOffset + (vy / 2) * mCaptureChromaStride + (vx / 2) * 2;
        s.u = {c, mCaptureChromaStride, 2};
        s.v = {c + 1, mCaptureChromaStride, 2};
        char geo[256];
        snprintf(geo, sizeof(geo),
                 "coded=%ux%u stride=%u cstride=%u yoff=%zu uvoff=%zu ysize=%zu uvsize=%zu "
                 "used=%zu/%zu",
                 width, height, mCaptureStride, mCaptureChromaStride, yOffset, uvOffset,
                 src->getPlaneSize(0), src->getPlaneSize(1), src->getPlaneBytesUsed(0),
                 src->getPlaneBytesUsed(1));
        mCap->source(static_cast<int32_t>(src->getTimeStamp().tv_sec), src->bufferId(), s, geo);
    }

    // Copy the coded rectangle; retain mVisibleRect for downstream cropping.
    // Copying only visible width/height from (0,0) broke non-zero crop offsets.
    if (!h96::copyNv12(y + yOffset, src->getPlaneSize(0) - yOffset, mCaptureStride,
                       uv + uvOffset, src->getPlaneSize(1) - uvOffset,
                       mCaptureChromaStride, width, height, dst[0], dst[1], dst[2]))
        return false;

    // Stage 2: the destination block after the copy, still mapped and not yet published.
    if (cap) {
        h96::FrameCapture::Stage d;
        d.y = {dst[0].data + vy * dst[0].rowStride + vx * dst[0].pixelStride, dst[0].rowStride,
               dst[0].pixelStride};
        d.u = {dst[1].data + (vy / 2) * dst[1].rowStride + (vx / 2) * dst[1].pixelStride,
               dst[1].rowStride, dst[1].pixelStride};
        d.v = {dst[2].data + (vy / 2) * dst[2].rowStride + (vx / 2) * dst[2].pixelStride,
               dst[2].rowStride, dst[2].pixelStride};
        char geo[256];
        snprintf(geo, sizeof(geo),
                 "Y{rs=%zu,ps=%zu} U{rs=%zu,ps=%zu} V{rs=%zu,ps=%zu} v-u=%td crop=%u,%u+%ux%u",
                 dst[0].rowStride, dst[0].pixelStride, dst[1].rowStride, dst[1].pixelStride,
                 dst[2].rowStride, dst[2].pixelStride, dst[2].data - dst[1].data, crop.left,
                 crop.top, crop.width, crop.height);
        mCap->destination(d, geo);
    }
    return true;
}

void V4L2Decoder::tryFetchVideoFrame() {
    ATRACE_CALL();
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());
    if (mState == State::Error) return;

    if (!mVideoFramePool) {
        ALOGE("mVideoFramePool is null, failed to get the instance after resolution change?");
        onError();
        return;
    }

    /* h96: MMAP-выход — клиентские блоки не связаны с V4L2-буферами,
     * свободных V4L2-буферов по замыслу нет (все у драйвера). Гейт по
     * freeBuffersCount навечно блокировал фетч. Вместо него — предел
     * очереди готовых блоков. */
    if (mUseDmabufOutput) {
        if (mOutputQueue->freeBuffersCount() == 0) {
            ALOGV("No free V4L2 output slot, wait for DQBUF.");
            return;
        }
    } else if (mReadyClientFrames.size() >= kMaxReadyClientFrames) {
        ALOGV("Enough client frames queued, ignore.");
        return;
    }

    if (mReuseFrameQueue.empty()) {
        if (!mVideoFramePool->getVideoFrame(
                    ::base::BindOnce(&V4L2Decoder::onVideoFrameReady, mWeakThis))) {
            ALOGV("%s(): Previous callback is running, ignore.", __func__);
        }

        return;
    }

    // Reuse output picture buffers that were abandoned after STREAMOFF first.
    // NOTE(b/270003218 and b/297228544): This avoids issues with lack of
    // ability to return all picture buffers on STREAMOFF from VDA and
    // saves on IPC with BufferQueue increasing overall responsiveness.
    uint32_t blockId = mReuseFrameQueue.front().first;
    std::unique_ptr<VideoFrame> frame = std::move(mReuseFrameQueue.front().second);
    mReuseFrameQueue.pop();

    // Avoid recursive calls
    mTaskRunner->PostTask(FROM_HERE, ::base::BindOnce(&V4L2Decoder::onVideoFrameReady, mWeakThis,
                                                      std::make_pair(std::move(frame), blockId)));
}

void V4L2Decoder::onVideoFrameReady(
        std::optional<VideoFramePool::FrameWithBlockId> frameWithBlockId) {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());
    if (mState == State::Error) return;

    if (!frameWithBlockId) {
        ALOGE("Got nullptr VideoFrame.");
        onError();
        return;
    }

    // Unwrap our arguments.
    std::unique_ptr<VideoFrame> frame;
    uint32_t blockId;
    std::tie(frame, blockId) = std::move(*frameWithBlockId);

    if (!mUseDmabufOutput) {
        /* h96: MMAP — блок ждёт готовый декодированный кадр для копии. */
        mReadyClientFrames.push(std::move(frame));
        tryOutputDecodedFrame();
        tryFetchVideoFrame();
        return;
    }

    /* h96 zero-copy: блок отправляется декодеру в свой (навсегда
     * закреплённый) v4l2-слот. */
    size_t v4l2Id;
    auto idIt = mBlockIdToV4L2Id.find(blockId);
    if (idIt != mBlockIdToV4L2Id.end()) {
        v4l2Id = idIt->second;
    } else if (mBlockIdToV4L2Id.size() < mOutputQueue->allocatedBuffersCount()) {
        v4l2Id = mBlockIdToV4L2Id.size();
        mBlockIdToV4L2Id.emplace(blockId, v4l2Id);
        ALOGV("h96: bind block %u -> v4l2 slot %zu", blockId, v4l2Id);
    } else {
        /* Незнакомый блок при полной карте: канвасы защёлкнуты, чужой
         * физадрес декодеру отдавать нельзя. Карантиним, чтобы пул не
         * гонял его нам по кругу. */
        ALOGV("h96: quarantine unknown block %u", blockId);
        mQuarantineBlocks.push_back(std::move(frame));
        if (mQuarantineBlocks.size() > 4)
            mQuarantineBlocks.erase(mQuarantineBlocks.begin());
        tryFetchVideoFrame();
        return;
    }

    auto ob = mOutputQueue->getFreeBuffer(v4l2Id);
    if (!ob) {
        ALOGE("h96: v4l2 slot %zu busy for block %u", v4l2Id, blockId);
        onError();
        return;
    }
    if (!std::move(*ob).queueDMABuf(frame->getFDs())) {
        ALOGE("h96: queueDMABuf failed (block %u, slot %zu)", blockId, v4l2Id);
        onError();
        return;
    }
    mFrameAtDevice.insert_or_assign(v4l2Id, std::move(frame));
    tryFetchVideoFrame();
}

std::optional<size_t> V4L2Decoder::getNumOutputBuffers() {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    struct v4l2_control ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE;
    if (mDevice->ioctl(VIDIOC_G_CTRL, &ctrl) != 0) {
        ALOGE("ioctl() failed: VIDIOC_G_CTRL");
        return std::nullopt;
    }
    ALOGV("%s() V4L2_CID_MIN_BUFFERS_FOR_CAPTURE returns %u", __func__, ctrl.value);

    return ctrl.value + kNumExtraOutputBuffers;
}

std::optional<struct v4l2_format> V4L2Decoder::getFormatInfo() {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    struct v4l2_format format;
    memset(&format, 0, sizeof(format));
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (mDevice->ioctl(VIDIOC_G_FMT, &format) != 0) {
        ALOGE("ioctl() failed: VIDIOC_G_FMT");
        return std::nullopt;
    }

    return format;
}

Rect V4L2Decoder::getVisibleRect(const ui::Size& codedSize) {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    struct v4l2_rect* visible_rect = nullptr;
    struct v4l2_selection selection_arg;
    memset(&selection_arg, 0, sizeof(selection_arg));
    selection_arg.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    selection_arg.target = V4L2_SEL_TGT_COMPOSE;

    if (mDevice->ioctl(VIDIOC_G_SELECTION, &selection_arg) == 0) {
        ALOGV("VIDIOC_G_SELECTION is supported");
        visible_rect = &selection_arg.r;
    } else {
        ALOGV("Fallback to VIDIOC_G_CROP");
        struct v4l2_crop crop_arg;
        memset(&crop_arg, 0, sizeof(crop_arg));
        crop_arg.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

        if (mDevice->ioctl(VIDIOC_G_CROP, &crop_arg) != 0) {
            ALOGW("ioctl() VIDIOC_G_CROP failed");
            return Rect(codedSize.width, codedSize.height);
        }
        visible_rect = &crop_arg.c;
    }

    Rect rect(visible_rect->left, visible_rect->top, visible_rect->left + visible_rect->width,
              visible_rect->top + visible_rect->height);
    ALOGV("visible rectangle is %s", toString(rect).c_str());
    if (!contains(Rect(codedSize.width, codedSize.height), rect)) {
        ALOGW("visible rectangle %s is not inside coded size %s", toString(rect).c_str(),
              toString(codedSize).c_str());
        return Rect(codedSize.width, codedSize.height);
    }
    if (rect.isEmpty()) {
        ALOGW("visible size is empty");
        return Rect(codedSize.width, codedSize.height);
    }

    return rect;
}

bool V4L2Decoder::sendV4L2DecoderCmd(bool start) {
    ALOGV("%s(start=%d)", __func__, start);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    struct v4l2_decoder_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.cmd = start ? V4L2_DEC_CMD_START : V4L2_DEC_CMD_STOP;
    if (mDevice->ioctl(VIDIOC_DECODER_CMD, &cmd) != 0) {
        ALOGE("ioctl() VIDIOC_DECODER_CMD failed: start=%d", start);
        return false;
    }

    return true;
}

void V4L2Decoder::onError() {
    ALOGV("%s()", __func__);
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState == State::Error) return;
    setState(State::Error);
    mErrorCb.Run();
}

void V4L2Decoder::setState(State newState) {
    ALOGV("%s(%s)", __func__, StateToString(newState));
    ALOG_ASSERT(mTaskRunner->RunsTasksInCurrentSequence());

    if (mState == newState) return;
    if (mState == State::Error) {
        ALOGV("Already in Error state.");
        return;
    }

    switch (newState) {
    case State::Idle:
        break;
    case State::Decoding:
        break;
    case State::Draining:
        if (mState != State::Decoding) newState = State::Error;
        break;
    case State::Error:
        break;
    }

    ALOGI("Set state %s => %s", StateToString(mState), StateToString(newState));
    mState = newState;
}

// static
const char* V4L2Decoder::StateToString(State state) {
    switch (state) {
    case State::Idle:
        return "Idle";
    case State::Decoding:
        return "Decoding";
    case State::Draining:
        return "Draining";
    case State::Error:
        return "Error";
    }
}

}  // namespace android
