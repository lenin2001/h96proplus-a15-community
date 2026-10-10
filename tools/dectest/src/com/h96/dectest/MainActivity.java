package com.h96.dectest;

import android.app.Activity;
import android.media.MediaCodec;
import android.media.MediaCodec.BufferInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Bundle;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.util.ArrayList;

// Controlled hardware-decode-to-Surface test for H96 Pro Plus.
// Forces the exact HW component (default c2.v4l2.avc.decoder), no software fallback.
// Two sources:
//   raw mode (extras raw=<annexb .264> idx=<pos size pts_us key per line>) — bypasses the
//            platform MediaExtractor (which crashes on this build: seccomp memfd_create).
//   extractor mode (extra file=<mp4>) — MediaExtractor path.
// Logs a single-frame trace with a session id under tag H96DEC.
public class MainActivity extends Activity implements SurfaceHolder.Callback {
    static final String TAG = "H96DEC";
    volatile boolean stop = false;
    Thread worker;
    long session;

    String path, rawPath, idxPath;
    String codecName;
    String mime;
    boolean doSeek;
    boolean realtime;
    boolean byteBufferMode;   // decode into an ImageReader Surface and log per-frame Y-plane MD5
    boolean hashFrames;       // 25.09: in byteBufferMode, false = acquire/close images without MD5 (output path without the hashing cost)
    int maxFrames;            // stop after N output frames in byteBufferMode (0 = all)
    int pauseAt, pauseMs;     // after pauseAt input AUs, stop FEEDING for pauseMs (output keeps draining) — simulates seek/buffering gap
    // h96 0027 stimulus: hold decoded images instead of returning them, which is what CCodec does
    // for reorder/rendering. This is the only way to starve the CAPTURE queue on purpose, and
    // CAPTURE starvation across a format change is the failure the driver patch addresses.
    int holdAt, holdN, holdMs; // after holdAt output frames, keep holdN images for holdMs
    int readerImages;         // depth of the ImageReader; must exceed holdN or we starve ourselves
    final java.util.ArrayList<android.media.Image> held = new java.util.ArrayList<android.media.Image>();
    long holdUntilNs = 0;
    android.media.ImageReader mReader;
    int width, height;
    int seekAfterAu;
    long seekToUs;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        session = System.nanoTime() % 1000000L;
        path = getIntent().getStringExtra("file");
        rawPath = getIntent().getStringExtra("raw");
        idxPath = getIntent().getStringExtra("idx");
        codecName = getIntent().getStringExtra("codec");
        if (codecName == null) codecName = "c2.v4l2.avc.decoder";
        mime = getIntent().getStringExtra("mime");
        if (mime == null) mime = "video/avc";
        doSeek = getIntent().getBooleanExtra("seek", false);
        realtime = getIntent().getBooleanExtra("realtime", true);
        width = getIntent().getIntExtra("w", 1920);
        height = getIntent().getIntExtra("h", 1080);
        seekAfterAu = getIntent().getIntExtra("seekAfter", 150);
        seekToUs = getIntent().getLongExtra("seekTo", 20000000L);
        byteBufferMode = getIntent().getBooleanExtra("bytebuffer", false);
        hashFrames = getIntent().getBooleanExtra("hash", true);
        maxFrames = getIntent().getIntExtra("maxFrames", 0);
        pauseAt = getIntent().getIntExtra("pauseAt", 0);      // after N input AUs, stop feeding for pauseMs
        pauseMs = getIntent().getIntExtra("pauseMs", 6000);   // simulates a buffering gap (seek refetch)
        holdAt = getIntent().getIntExtra("holdAt", 0);        // 0 = never hold
        holdN = getIntent().getIntExtra("holdN", 4);
        holdMs = getIntent().getIntExtra("holdMs", 4000);
        // Deep enough that holding holdN images still leaves frames to acquire and hash. With the
        // old fixed depth of six, holding four left two, and most frames could not be read at all.
        readerImages = getIntent().getIntExtra("readerImages", 0);
        if (readerImages <= 0) readerImages = Math.max(6, holdN + 6);
        Log.i(TAG, "sess=" + session + " onCreate file=" + path + " raw=" + rawPath + " idx=" + idxPath + " codec=" + codecName + " seek=" + doSeek + " realtime=" + realtime);
        SurfaceView sv = new SurfaceView(this);
        sv.getHolder().addCallback(this);
        setContentView(sv);
    }

    @Override public void surfaceCreated(SurfaceHolder h) {
        final Surface surface = h.getSurface();
        worker = new Thread(new Runnable() {
            public void run() {
                try {
                    if (rawPath != null) decodeRaw(surface); else decodeExtractor(surface);
                } catch (Throwable t) { Log.e(TAG, "sess=" + session + " FATAL", t); }
            }
        }, "dec");
        worker.start();
    }
    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) {}
    @Override public void surfaceDestroyed(SurfaceHolder h) { stop = true; }
    @Override protected void onDestroy() { stop = true; super.onDestroy(); }

    // ---- raw Annex-B + index ------------------------------------------------------------
    static class Au { long pos; int size; long pts; boolean key; }

    ArrayList<Au> loadIndex(String p) throws Exception {
        ArrayList<Au> list = new ArrayList<Au>();
        BufferedReader r = new BufferedReader(new FileReader(p));
        String line;
        while ((line = r.readLine()) != null) {
            String[] f = line.trim().split("\\s+");
            if (f.length < 4) continue;
            Au a = new Au();
            a.pos = Long.parseLong(f[0]); a.size = Integer.parseInt(f[1]);
            a.pts = Long.parseLong(f[2]); a.key = f[3].equals("1");
            list.add(a);
        }
        r.close();
        return list;
    }

    // Split first AU into NAL units; extract parameter sets as csd.
    // H264: SPS(7)->csd-0, PPS(8)->csd-1. HEVC: VPS(32)+SPS(33)+PPS(34) concatenated->csd-0.
    void addCsd(MediaFormat fmt, byte[] au) {
        boolean hevc = mime.equals("video/hevc");
        int n = au.length;
        int i = 0;
        ArrayList<int[]> nals = new ArrayList<int[]>();
        while (i + 3 < n) {
            if (au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1) {
                int start = i - (i > 0 && au[i - 1] == 0 ? 1 : 0);
                int j = i + 3;
                while (j + 3 < n && !(au[j] == 0 && au[j + 1] == 0 && au[j + 2] == 1)) j++;
                int end = (j + 3 < n) ? (j - (au[j - 1] == 0 ? 1 : 0)) : n;
                int type = hevc ? ((au[i + 3] >> 1) & 0x3f) : (au[i + 3] & 0x1f);
                nals.add(new int[]{start, end, type});
                i = j;
            } else i++;
        }
        int csd = 0;
        if (hevc) {
            int total = 0;
            for (int[] nal : nals) if (nal[2] == 32 || nal[2] == 33 || nal[2] == 34) total += nal[1] - nal[0];
            ByteBuffer bb = ByteBuffer.allocate(total);
            for (int[] nal : nals) if (nal[2] == 32 || nal[2] == 33 || nal[2] == 34) { bb.put(au, nal[0], nal[1] - nal[0]); csd++; }
            bb.flip();
            fmt.setByteBuffer("csd-0", bb);
            Log.i(TAG, "sess=" + session + " HEVC csd-0 paramset-nals=" + csd + " bytes=" + total);
        } else {
            for (int[] nal : nals) {
                if (nal[2] == 7 || nal[2] == 8) {
                    ByteBuffer bb = ByteBuffer.allocate(nal[1] - nal[0]);
                    bb.put(au, nal[0], nal[1] - nal[0]); bb.flip();
                    String key = nal[2] == 7 ? "csd-0" : "csd-1";
                    fmt.setByteBuffer(key, bb);
                    Log.i(TAG, "sess=" + session + " " + key + " nal=" + nal[2] + " bytes=" + (nal[1] - nal[0]));
                    csd++;
                }
            }
        }
        Log.i(TAG, "sess=" + session + " first AU nals=" + nals.size() + " csd set=" + csd);
    }

    void decodeRaw(Surface surface) throws Exception {
        ArrayList<Au> idx = loadIndex(idxPath);
        RandomAccessFile raf = new RandomAccessFile(rawPath, "r");
        Log.i(TAG, "sess=" + session + " raw size=" + raf.length() + " AUs=" + idx.size());
        MediaFormat fmt = MediaFormat.createVideoFormat(mime, width, height);
        byte[] first = new byte[idx.get(0).size];
        raf.seek(idx.get(0).pos); raf.readFully(first);
        addCsd(fmt, first);
        Log.i(TAG, "sess=" + session + " fmt=" + fmt);

        MediaCodec codec = MediaCodec.createByCodecName(codecName);
        Log.i(TAG, "sess=" + session + " created codec=" + codec.getName() + " (requested " + codecName + ")");
        if (!codec.getName().equals(codecName)) Log.e(TAG, "sess=" + session + " WRONG COMPONENT (fallback?) got=" + codec.getName());
        Surface target = surface;
        if (byteBufferMode) {
            // HW path needs a real gralloc Surface; ImageReader gives one AND lets us read the Y plane.
            mReader = android.media.ImageReader.newInstance(width, height, android.graphics.ImageFormat.YUV_420_888, readerImages);
            target = mReader.getSurface();
            Log.i(TAG, "sess=" + session + " ImageReader surface " + width + "x" + height
                    + " YUV_420_888 depth=" + readerImages + " holdN=" + holdN
                    + " (pixel-readable HW output)");
        }
        codec.configure(fmt, target, null, 0);
        codec.start();
        Log.i(TAG, "sess=" + session + " codec.start done, entering loop");
        runLoop(codec, new RawSource(raf, idx));
    }

    interface Source { int next(ByteBuffer dst, long[] ptsOut); boolean seek(long targetUs); void close(); }

    class RawSource implements Source {
        RandomAccessFile raf; ArrayList<Au> idx; int i = 0;
        RawSource(RandomAccessFile r, ArrayList<Au> l) { raf = r; idx = l; }
        public int next(ByteBuffer dst, long[] ptsOut) {
            if (i >= idx.size()) return -1;
            Au a = idx.get(i++);
            try {
                byte[] buf = new byte[a.size];
                raf.seek(a.pos); raf.readFully(buf);
                dst.clear(); dst.put(buf);
                ptsOut[0] = a.pts;
                return a.size;
            } catch (Exception e) { Log.e(TAG, "sess=" + session + " read AU " + (i - 1) + " failed", e); return -1; }
        }
        public boolean seek(long targetUs) {
            for (int k = 0; k < idx.size(); k++) {
                if (idx.get(k).key && idx.get(k).pts >= targetUs) { i = k; Log.i(TAG, "sess=" + session + " seek -> AU " + k + " pts=" + idx.get(k).pts); return true; }
            }
            return false;
        }
        public void close() { try { raf.close(); } catch (Exception e) {} }
    }

    class ExtractorSource implements Source {
        MediaExtractor ex;
        ExtractorSource(MediaExtractor e) { ex = e; }
        public int next(ByteBuffer dst, long[] ptsOut) {
            int sz = ex.readSampleData(dst, 0);
            if (sz < 0) return -1;
            ptsOut[0] = ex.getSampleTime();
            ex.advance();
            return sz;
        }
        public boolean seek(long targetUs) { ex.seekTo(targetUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC); return true; }
        public void close() { ex.release(); }
    }

    void decodeExtractor(Surface surface) throws Exception {
        File file = new File(path);
        Log.i(TAG, "sess=" + session + " file exists=" + file.exists() + " size=" + file.length());
        MediaExtractor ex = new MediaExtractor();
        ex.setDataSource(path);
        int vt = -1; MediaFormat fmt = null;
        for (int i = 0; i < ex.getTrackCount(); i++) {
            MediaFormat f = ex.getTrackFormat(i);
            String mime = f.getString(MediaFormat.KEY_MIME);
            Log.i(TAG, "sess=" + session + " track " + i + " mime=" + mime + " fmt=" + f);
            if (mime != null && mime.startsWith("video/")) { vt = i; fmt = f; break; }
        }
        if (vt < 0) { Log.e(TAG, "sess=" + session + " no video track"); return; }
        ex.selectTrack(vt);
        MediaCodec codec = MediaCodec.createByCodecName(codecName);
        Log.i(TAG, "sess=" + session + " created codec=" + codec.getName() + " (requested " + codecName + ")");
        Surface target = surface;
        if (byteBufferMode) {
            // HW path needs a real gralloc Surface; ImageReader gives one AND lets us read the Y plane.
            mReader = android.media.ImageReader.newInstance(width, height, android.graphics.ImageFormat.YUV_420_888, readerImages);
            target = mReader.getSurface();
            Log.i(TAG, "sess=" + session + " ImageReader surface " + width + "x" + height
                    + " YUV_420_888 depth=" + readerImages + " holdN=" + holdN
                    + " (pixel-readable HW output)");
        }
        codec.configure(fmt, target, null, 0);
        codec.start();
        runLoop(codec, new ExtractorSource(ex));
    }

    void runLoop(MediaCodec codec, Source src) {
        BufferInfo info = new BufferInfo();
        long t0 = System.nanoTime();
        long inCount = 0, outCount = 0, rendered = 0, lastLogSec = -1;
        long firstOutNs = -1;
        boolean inEos = false, seeked = false;
        long lastPts = -1;
        long[] pts = new long[1];
        long ptsBase = 0; // pts offset after seek so pacing stays realtime
        long feedPausedUntil = 0; boolean paused = false;
        long lastQueueNs = 0;     // 25.09: input gap log (> 50 ms between queued AUs)

        while (!stop) {
            // Release the deliberately held images once their window has expired. This is the
            // "late CAPTURE buffer" the decoder has been waiting for.
            if (!held.isEmpty() && holdUntilNs > 0 && System.nanoTime() >= holdUntilNs) {
                Log.i(TAG, "sess=" + session + " RELEASE " + held.size()
                        + " held images (out=" + outCount + ", in=" + inCount + ")");
                for (android.media.Image im : held) { try { im.close(); } catch (Throwable t) {} }
                held.clear();
                holdUntilNs = 0;
                holdAt = 0; // hold once per run; the point is one clean starvation event
            }
            if (paused && feedPausedUntil > 0 && System.nanoTime() >= feedPausedUntil) {
                Log.i(TAG, "sess=" + session + " RESUME input feed (out now=" + outCount + ", in=" + inCount + ")");
                feedPausedUntil = 0;
            }
            if (!inEos && feedPausedUntil == 0) {
                int inIdx = codec.dequeueInputBuffer(10000);
                if (inIdx >= 0) {
                    ByteBuffer ib = codec.getInputBuffer(inIdx);
                    int sz = src.next(ib, pts);
                    if (sz < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                        inEos = true;
                        Log.i(TAG, "sess=" + session + " input EOS after " + inCount + " AUs");
                    } else {
                        codec.queueInputBuffer(inIdx, 0, sz, pts[0], 0);
                        long qNs = System.nanoTime();
                        if (lastQueueNs > 0 && qNs - lastQueueNs > 50000000L)
                            Log.i(TAG, "sess=" + session + " GAP before AU " + inCount + " gapMs=" + ((qNs - lastQueueNs) / 1000000L)
                                    + " pending=" + (inCount - outCount) + " out=" + outCount);
                        lastQueueNs = qNs;
                        if (inCount < 5 || (seeked && inCount < seekAfterAu + 5)) Log.i(TAG, "sess=" + session + " IN #" + inCount + " size=" + sz + " ptsUs=" + pts[0]);
                        inCount++;
                        if (pauseAt > 0 && !paused && inCount == pauseAt) {
                            paused = true; feedPausedUntil = System.nanoTime() + pauseMs * 1000000L;
                            Log.i(TAG, "sess=" + session + " PAUSE input feed " + pauseMs + " ms after AU " + inCount + " (out so far=" + outCount + ")");
                        }
                        if (doSeek && !seeked && inCount == seekAfterAu) {
                            Log.i(TAG, "sess=" + session + " SEEK: flush + jump to " + seekToUs + "us (after " + inCount + " AUs, out so far=" + outCount + ")");
                            codec.flush();
                            src.seek(seekToUs);
                            seeked = true;
                            t0 = System.nanoTime(); ptsBase = seekToUs;
                        }
                    }
                }
            }
            int outIdx = codec.dequeueOutputBuffer(info, 10000);
            if (outIdx >= 0) {
                if (firstOutNs < 0) {
                    firstOutNs = System.nanoTime();
                    Log.i(TAG, "sess=" + session + " FIRST OUTPUT after " + ((firstOutNs - t0) / 1000000) + " ms, ptsUs=" + info.presentationTimeUs + " size=" + info.size + " flags=" + info.flags + " (inputs so far=" + inCount + ")");
                }
                if (outCount < 5) Log.i(TAG, "sess=" + session + " OUT #" + outCount + " idx=" + outIdx + " size=" + info.size + " ptsUs=" + info.presentationTimeUs + " flags=" + info.flags);
                boolean render = info.size != 0;
                if (byteBufferMode && info.size != 0) {
                    // Deterministic-codec correctness check: render into the ImageReader Surface,
                    // then read back the stride-normalized Y plane and hash it.
                    if (realtime) {   // 25.09: pacing is independent of the output path now
                        long due = t0 + (info.presentationTimeUs - ptsBase) * 1000L;
                        long sleep = (due - System.nanoTime()) / 1000000L;
                        if (sleep > 1 && sleep < 2000) { try { Thread.sleep(sleep); } catch (InterruptedException e) {} }
                    }
                    codec.releaseOutputBuffer(outIdx, true);
                    outCount++; lastPts = info.presentationTimeUs;
                    try {
                        android.media.Image img = null;
                        for (int w8 = 0; w8 < 40 && img == null; w8++) { img = mReader.acquireNextImage(); if (img == null) Thread.sleep(5); }
                        if (img == null) { Log.w(TAG, "sess=" + session + " no image for pts=" + info.presentationTimeUs); }
                        else {
                            long ipts = img.getTimestamp() / 1000L;
                            android.media.Image.Plane[] pl = img.getPlanes();
                            int w = img.getWidth(), hgt = img.getHeight();
                            // Chroma is half resolution in both directions for 4:2:0. A luma-only
                            // hash cannot see a chroma-plane or chroma-stride defect, which is
                            // exactly the kind that shows up as coloured vertical bands.
                            String ym = hashFrames ? md5Plane(pl[0], w, hgt) : "nohash";
                            String um = hashFrames && pl.length > 1 ? md5Plane(pl[1], w / 2, hgt / 2) : "-";
                            String vm = hashFrames && pl.length > 2 ? md5Plane(pl[2], w / 2, hgt / 2) : "-";
                            if (outCount == 1) {
                                StringBuilder geo = new StringBuilder();
                                geo.append("sess=").append(session).append(" PLANES fmt=").append(img.getFormat())
                                   .append(" size=").append(w).append("x").append(hgt)
                                   .append(" crop=").append(img.getCropRect());
                                for (int pi = 0; pi < pl.length; pi++) {
                                    geo.append(" p").append(pi).append("[rs=").append(pl[pi].getRowStride())
                                       .append(",ps=").append(pl[pi].getPixelStride())
                                       .append(",cap=").append(pl[pi].getBuffer().capacity()).append("]");
                                }
                                Log.i(TAG, geo.toString());
                            }
                            Log.i(TAG, "sess=" + session + " FRAME " + outCount + " pts=" + ipts + " " + w + "x" + hgt
                                    + " ymd5=" + ym + " umd5=" + um + " vmd5=" + vm);
                            // Starve the CAPTURE queue on purpose: keep the image (and therefore
                            // the gralloc buffer) instead of handing it back.
                            if (holdAt > 0 && outCount >= holdAt && held.size() < holdN) {
                                held.add(img);
                                if (held.size() == 1) holdUntilNs = System.nanoTime() + holdMs * 1000000L;
                                Log.i(TAG, "sess=" + session + " HOLD image " + held.size() + "/" + holdN
                                        + " at frame " + outCount + " (" + w + "x" + hgt + ") for " + holdMs + " ms");
                            } else {
                                img.close();
                            }
                        }
                    } catch (Throwable t) { Log.e(TAG, "sess=" + session + " ymd5 failed", t); }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) { Log.i(TAG, "sess=" + session + " OUTPUT EOS"); break; }
                    if (maxFrames > 0 && outCount >= maxFrames) { Log.i(TAG, "sess=" + session + " maxFrames reached"); break; }
                    continue;
                }
                if (realtime && render) {
                    long due = t0 + (info.presentationTimeUs - ptsBase) * 1000L;
                    long sleep = (due - System.nanoTime()) / 1000000L;
                    if (sleep > 1 && sleep < 2000) { try { Thread.sleep(sleep); } catch (InterruptedException e) {} }
                }
                codec.releaseOutputBuffer(outIdx, render);
                if (render) rendered++;
                outCount++;
                lastPts = info.presentationTimeUs;
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) { Log.i(TAG, "sess=" + session + " OUTPUT EOS"); break; }
                if (byteBufferMode && maxFrames > 0 && outCount >= maxFrames) { Log.i(TAG, "sess=" + session + " maxFrames reached"); break; }
            } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                Log.i(TAG, "sess=" + session + " OUTPUT_FORMAT_CHANGED " + codec.getOutputFormat());
            }
            long sec = (System.nanoTime() - t0) / 1000000000L;
            if (sec != lastLogSec) {
                lastLogSec = sec;
                Log.i(TAG, "sess=" + session + " t=" + sec + "s in=" + inCount + " out=" + outCount + " rendered=" + rendered + " lastPtsMs=" + (lastPts / 1000));
            }
        }
        Log.i(TAG, "sess=" + session + " END in=" + inCount + " out=" + outCount + " rendered=" + rendered);
        try { codec.stop(); codec.release(); } catch (Throwable t) {}
        if (mReader != null) { try { mReader.close(); } catch (Throwable t) {} }
        src.close();
    }

    /**
     * MD5 of one plane, normalized to w x h actual samples.
     *
     * Row stride and pixel stride are both honoured: a semi-planar layout gives the chroma planes
     * a pixel stride of 2, and the row stride is padding that must not enter the hash or two
     * identical pictures with different alignment would compare as different. Reads are clamped to
     * the buffer, because the last row of a plane is not guaranteed to be padded to a full stride.
     */
    static String md5Plane(android.media.Image.Plane p, int w, int h) {
        try {
            ByteBuffer b = p.getBuffer();
            int rs = p.getRowStride(), ps = p.getPixelStride(), cap = b.capacity();
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("MD5");
            byte[] row = new byte[w];
            for (int r = 0; r < h; r++) {
                int base = r * rs;
                if (ps == 1) {
                    int n = Math.min(w, cap - base);
                    if (n <= 0) break;
                    b.position(base);
                    b.get(row, 0, n);
                    md.update(row, 0, n);
                } else {
                    int n = 0;
                    for (int c = 0; c < w; c++) {
                        int off = base + c * ps;
                        if (off >= cap) break;
                        row[n++] = b.get(off);
                    }
                    if (n == 0) break;
                    md.update(row, 0, n);
                }
            }
            StringBuilder sb = new StringBuilder();
            for (byte bb : md.digest()) sb.append(String.format("%02x", bb));
            return sb.toString();
        } catch (Throwable t) {
            return "ERR";
        }
    }
}
