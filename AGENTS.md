# Instructions for human and AI contributors

These rules apply to everyone working in this repository. They do not
authorise changes to any maintainer's live device.

## Start here

Read README.md, STATUS.md, HISTORY.md, DEVELOPMENT.md and release-manifest.json.
The patch order is defined only by kernel/patches/series.json and
aosp-patches/series.json, never by file numbers. The board layout the installer
accepts lives in installer/boards/; run `python3 -m unittest discover -s
installer/tests` after any change to installer/. The base revisions are pinned
there too: Linux v7.1 and AOSP android-15.0.0_r36; build helpers are in build/.
Establish the actual checkout, effective source trees, installed artifacts
when a device is available, and outstanding owner observations. Do not use
an older session summary as the current state.

Keep evidence labels explicit: source reasoning, host test, device measurement,
owner observation, untested. Never claim a device test from a successful build,
a passing mock, or another agent's narrative alone.

## Engineering

Work autonomously on inspection, local changes, builds and reversible tests
within the user's authorised scope. Choose the smallest useful experiment
that distinguishes hypotheses. After about 30 minutes without new evidence,
record the obstacle and change approach or move to an independent task;
a running healthy build is not a reason for speculative edits.

Preserve unrelated and uncommitted work. Use an isolated checkout/output.
Do not apply every numbered patch: consult the active series and exclude
superseded files and experiments. Export any necessary build-host-only changes
before claiming reproducibility.

Use precise terms: V4L2 OUTPUT is compressed input; CAPTURE is decoded output.
Frame delivery is not pixel correctness. A direct CDN URL is not the Alfa
proxy path. A timer resume is not physical remote acceptance. Network traffic
does not prove PHY interrupts or link-change handling work.

Do not silently turn a failed test into a pass by changing codec, resolution,
clock, source, test duration or error filter. Document any workaround and its
cost separately from a root-cause repair.

## Hardware and privacy

Never flash a different board using a maintainer's CID, fixed offsets or
private backup. Flash only with the authorised target, verified compatibility,
backups, partition bounds, pre-write hashes and read-back verification.
Unknown identity/layout is a refusal, not an invitation to remove the guard.

Do not alter bootloader/DDR-init, secure firmware, efuses or unique calibration
as routine work. Preserve the established eMMC installation. SD is a guarded
rescue environment. A clean release test does not authorise wiping owner data.

Never publish account data, credentials, full device dumps, application backups,
raw personal logs or private signing keys. Sanitise test evidence. Keep required
upstream authorship and licence notices. Source availability does not by itself
permit redistribution of every firmware blob or APK.

## Completion

Run the checks relevant to the changed path and a bounded regression set.
Stop optional repetition when it no longer resolves a concrete uncertainty.
No indefinite background traces or unbounded frame dumps.

Commit coherent changes with a reason, actual validation and rollback.
Update STATUS.md and HISTORY.md for changed conclusions. Record artifact hashes,
remaining limitations and the next executable action. Leave diagnostics off and
the device usable. Reports should help the next contributor continue without
the original maintainer's machine or account.
