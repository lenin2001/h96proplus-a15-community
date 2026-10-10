"""Source/config regression checks; these are NOT hardware or AOSP build tests."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

class IntegrationTests(unittest.TestCase):
    def test_mouse_packaged_and_has_domain(self):
        mk = read("device/h96proplus/device.mk")
        self.assertRegex(mk, r"irkeymap\s*\\\s*h96mouse")
        self.assertIn("/usr/keylayout/h96-remote.kl", mk)
        self.assertIn("h96mouse_exec", read("device/h96proplus/sepolicy/file_contexts"))
        self.assertIn("init_daemon_domain(h96mouse)", read("device/h96proplus/sepolicy/h96mouse.te"))
        self.assertNotIn("vendor_init", read("device/h96proplus/h96mouse/h96mouse.rc"))
        self.assertIn('init_rc: ["h96mouse.rc"]', read("device/h96proplus/h96mouse/Android.bp"))

    def test_raw_ir_and_measured_toggle(self):
        dts = read("dt/meson-gxm-h96proplus.dts")
        self.assertRegex(dts, r'&ir\s*\{\s*compatible = "amlogic,meson-gxbb-ir"')
        self.assertRegex(read("device/h96proplus/remote/h96-remote.map"),
                         r"(?m)^0x100\s+183\b")
        self.assertIn("CONFIG_INPUT_UINPUT=y", read("kernel/config/h96proplus_defconfig"))

    def test_shutdown_overlay_matches_patch(self):
        root = ET.fromstring(read("device/h96proplus/overlay/frameworks/base/core/res/res/values/config.xml"))
        self.assertEqual(root.find("./integer[@name='config_shortPressOnPowerBehavior']").text, "100")
        patch = read("aosp-patches/0012-framework-short-power-clean-shutdown.patch")
        self.assertIn("SHORT_PRESS_POWER_SHUTDOWN_NO_CONFIRM = 100", patch)
        self.assertIn("mWindowManagerFuncs.shutdown(false)", patch)
        self.assertNotIn("orderly_poweroff", patch)

    def test_capture_is_mmap_and_queued_before_streamon(self):
        src = read("aosp-overlay/external/v4l2_codec2/v4l2/V4L2Decoder.cpp")
        self.assertNotRegex(src, r"startOutputQueue\([^;]+V4L2_MEMORY_DMABUF")
        start = src.split("bool V4L2Decoder::startOutputQueue(", 1)[1].split("void V4L2Decoder::decode(", 1)[0]
        self.assertLess(start.index("queueMMap()"), start.index("mOutputQueue->streamon()"))
        self.assertLess(start.index("mDecodedMmapFrames.pop()"), start.index("deallocateBuffers()"))
        self.assertLess(start.index("deallocateBuffers()"), start.index("setupOutputFormat("))
        flush = src.split("void V4L2Decoder::flush()", 1)[1].split("void V4L2Decoder::serviceDeviceTask", 1)[0]
        self.assertLess(flush.index("queueMMap()"), flush.index("mOutputQueue->streamon()"))
        self.assertIn("mDecodedMmapFrames.push(std::move(dequeuedBuffer))", src)

    def test_copy_unmaps_and_allocator_reports_errors(self):
        src = read("aosp-overlay/external/v4l2_codec2/v4l2/V4L2Decoder.cpp")
        method = src.split("void V4L2Decoder::tryOutputDecodedFrame()", 1)[1].split("bool V4L2Decoder::copyMmapFrame", 1)[0]
        self.assertLess(method.index("copyMmapFrame(src, frame.get())"), method.index("mOutputCb.Run"))
        self.assertNotIn("C2GraphicView view =", method)
        pool = read("aosp-overlay/external/v4l2_codec2/components/VideoFramePool.cpp")
        self.assertIn("C2MemoryUsage::CPU_WRITE", pool)
        error = pool.split("if (err != C2_OK) {", 1)[1].split("ALOG_ASSERT(block", 1)[0]
        self.assertIn("mClientWeakThis, std::nullopt", error)
        self.assertIn("if (mBuffers.size() < mMaxBufferCount)", pool)

if __name__ == "__main__":
    unittest.main()
