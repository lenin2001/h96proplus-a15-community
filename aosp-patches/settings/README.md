# AOSP source patches applied to the installed image

These are source changes to the AOSP Settings app that were installed on the maintainer's
unit. They live here so the installed artefact can be reproduced from public sources.

## 0001-settings-homepage-let-leanback-rows-take-focus.patch

**What it fixes.** `SettingsHomepageActivity.initHomepageContainer()` makes the homepage container
focusable and takes the focus itself. On a handset that stops an inner `RecyclerView` from
grabbing focus and scrolling; on a leanback device it is the defect. The container is not
clickable, so the D-pad has nothing to activate — measured on the box as exactly one focused node,
`com.android.settings:id/homepage_container`, alongside nine clickable rows that never take focus,
and an OK press that does nothing.

The patch keeps handset behaviour byte-for-byte and diverges only when
`FEATURE_LEANBACK` is present.

**Applies to:** `packages/apps/Settings/src/com/android/settings/homepage/SettingsHomepageActivity.java`
at the tree that produced the installed image.

**Build recipe** — the release config must match the one the installed image was built with, or
soong re-analyses the whole tree and the resulting apk no longer matches the running system:

```sh
cd "$AOSP_ROOT"                                 # your AOSP checkout
export OUT_DIR=out
source build/envsetup.sh                       # never with `set -u`: envsetup dies under nounset
lunch h96proplus-trunk_staging-userdebug       # never through a pipe: a subshell loses TARGET_*
SOONG_GOMEMLIMIT=14GiB m -j3 Settings
```

Output: `out/target/product/h96proplus/system/system_ext/priv-app/Settings/Settings.apk`

**Installing on a running unit.** The rebuilt `Settings.apk` is signed with the same platform
key as the system image (AOSP test-keys in a developer build), so it can update the system app
in place: `adb install -r -d Settings.apk` keeps `sharedUser android.uid.system`; roll back with
`adb shell pm uninstall com.android.settings`. A key mismatch is refused by the package manager.

To check that the patch is in a rebuilt apk, do not compare sizes: the old and new apks had the
**same total byte count**. What shows it: `classes2.dex` grows by 108 bytes and `setDescendantFocusability` appears twice in the new
dex against once in the old.

## 0002-settings-screen-size-page.patch

**What it adds.** Settings → Display → **Размер экрана**: a D-pad page that pulls the whole
picture in from the edges of a television that overscans. 80–100 %, one percent per key press,
default 100 %.

The display-side consumer is `aosp-patches/0015-framework-display-size-percent.patch`; without it
this page writes a setting that nothing reads. Install them together.

**Files**

| File | Role |
| --- | --- |
| `src/…/display/ScreenSizeSettings.java` | the page: slider, confirmation with a 15 s countdown, reset, the preview lifecycle |
| `src/…/display/ScreenSizeSeekBarPreference.java` | a slider whose centre key confirms instead of being swallowed |
| `src/…/display/ScreenSizeBorderView.java` | the frame over the whole screen: four edges, corner arms, centre cross |
| `src/…/display/ScreenSizePreferenceController.java` | the summary on the Display row |
| `res/xml/screen_size_settings.xml` | the page |
| `res/xml/display_settings.xml` | the row, next to `screen_resolution` |
| `res/values/strings.xml`, `res/values-ru/strings.xml` | English and Russian labels |

**Behaviour**

* LEFT/RIGHT move one percent. The range is 20, so Android's own `KeyProgressIncrement`
  (`max(1, round(range / 20))`) is exactly 1 — no override needed.
* The preview *is* the screen: each step writes `screen_size_percent_preview`, which the display
  service applies immediately.
* OK confirms and opens the countdown dialog («Оставить» / «Вернуть»). Fifteen seconds with no
  answer reverts. BACK, or leaving the page, reverts.
* «Сбросить до 100%» applies at once without asking — a full-size picture cannot hide its own
  confirmation.
* Only a confirmed size is written to `screen_size_percent`, and that is the one that survives a
  reboot.
* If Settings dies mid-adjustment, the display service drops the preview after 20 s. An
  unconfirmed value can never become the permanent one.

**Build recipe** — same constraints as `0001`; the release config must match the installed image:

```sh
cd "$AOSP_ROOT"                                 # your AOSP checkout
export OUT_DIR=out
source build/envsetup.sh                       # never with `set -u`
lunch h96proplus-trunk_staging-userdebug       # never through a pipe
SOONG_GOMEMLIMIT=14GiB m -j3 services Settings
```

Outputs:

* `out/target/product/h96proplus/system/system_ext/priv-app/Settings/Settings.apk`
* `out/target/product/h96proplus/system/framework/services.jar`

**Installation.** The apk goes in the way `0001` did — `adb install -r -d Settings.apk`, which
lands in `/data` as an update to the system app and is undone with
`adb shell pm uninstall com.android.settings`. `services.jar` cannot: `/system` is EROFS and this
build refuses `adb remount` (the kernel has no `overlay` in `/proc/filesystems` and adbd reports
"Device must be bootloader unlocked"). It therefore needs a rebuilt `system.img` written through
the rescue installer, with the previous image kept as the rollback.

### What the box taught us, which the first version got wrong

Three defects only showed up on the device. They are worth recording because any other D-pad page
in this Settings build will hit the same three.

1. **The slider moved five percent per press, not one.** `AbsSeekBar` works its key step out from
   the range — `max(1, round(range / 20))` — which over 80…100 is 5. Fixed by calling
   `setKeyProgressIncrement(1)` in `onBindViewHolder`.

2. **OK on the slider did nothing.** `SeekBarPreference` installs its key listener on the *row*,
   but on a television the `SeekBar` itself is what takes focus, so the centre key never reached
   the row's listener. Fixed by installing a second listener on the bar itself.

3. **Nothing takes focus on its own, and the toolbar wins when something finally does.** Opening
   the page left focus nowhere; the first arrow key handed it to the toolbar's navigation button,
   two presses away from the slider. Worse, the confirmation dialog opened with *neither* button
   focused, so OK fell on the floor and every size reverted on the timeout.

   Fixed in three places: the toolbar leaves the focus order while this page is open (BACK still
   leaves, which is what the page tells the owner to use); the slider asks for focus on a short
   delay, once the rows are bound; and the dialog asks for focus on its positive button from an
   `OnShowListener` — not straight after `show()`, where the window has not taken focus yet and
   the request is lost. A dialog key listener is kept as a fallback: if focus still does not
   arrive, OK keeps and BACK reverts, and it steps aside as soon as a button does have focus.

Measured afterwards on the box: the page opens with the slider focused, seven LEFT presses move
it 100 → 94, OK opens the countdown, OK again stores `screen_size_percent=94`, and the value is
still there after leaving the page.
