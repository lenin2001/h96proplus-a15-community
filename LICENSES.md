# Лицензии и происхождение компонентов

У проекта **нет единой лицензии на всё**. Корневой [`LICENSE`](LICENSE)
(Apache-2.0) относится только к файлам, написанным для этого проекта и не
несущим собственного заголовка. Всё, что происходит из Linux, AOSP, ChromiumOS
и других проектов, остаётся под их лицензиями — заголовки внутри файлов
главнее этой таблицы.

## Что лежит в репозитории

| Путь | Происхождение | Лицензия |
|---|---|---|
| `installer/`, `rescue/` (скрипты и `init`), `build/`, `tests/`, `tools/` (кроме отмеченного ниже), `launcher/` (исходники MovieLauncher), `device/h96proplus/` (makefile, rc, скрипты, оверлеи, sepolicy, `remote/irkeymap.c`), документация | написано для проекта | Apache-2.0 (`LICENSE`) |
| `device/h96proplus/h96mouse/` | написано для проекта | **GPL-2.0** (SPDX в файлах) |
| `device/h96proplus/remote/keylayout/*.kl` | AOSP `frameworks/base/data/keyboards` (37 файлов с заголовком AOSP); `Vendor_0001_Product_0001.kl` написан для проекта | Apache-2.0 |
| `kernel/patches/**`, `kernel/meson_gx_pm.c` | изменения ядра Linux; серия HEVC — авторы из рассылки linux-media (см. заголовки патчей) | **GPL-2.0** (как изменяемые файлы ядра) |
| `kernel/config/h96proplus_defconfig` | конфигурация ядра Linux | GPL-2.0 (часть сборки ядра) |
| `dt/meson-gxm-h96proplus.dts` | основан на mainline `meson-gxm-q200.dts` | GPL-2.0+ OR MIT (SPDX в файле) |
| `aosp-overlay/external/v4l2_codec2/` | AOSP/ChromiumOS `external/v4l2_codec2` с изменениями проекта | BSD-3-Clause (см. `NOTICE`, `MODULE_LICENSE_BSD` в каталоге) |
| `aosp-overlay/external/v4l2_codec2/tests/c2_comp_intf/data/bear*` | тестовые ролики upstream, побайтно совпадают с AOSP `main` (проверено 2026-10-10) | как модуль |
| `aosp-overlay/external/minigbm/` | ChromiumOS minigbm с изменениями | BSD-3-Clause (The Chromium OS Authors) |
| `aosp-overlay/frameworks/av/…`, `aosp-overlay/hardware/interfaces/…`, `aosp-overlay/system/media/…` | AOSP с изменениями | Apache-2.0 |
| `aosp-patches/*.patch` | изменения проектов AOSP | лицензия изменяемого проекта: Apache-2.0 (frameworks, build, system/core, packages/apps/Settings, drm_hwcomposer), BSD (minigbm, v4l2_codec2) |
| `launcher/gradle/wrapper/gradle-wrapper.jar` | Gradle 8.11.1; SHA-256 `2db75c40…48046` совпадает с официальным `gradle-8.11.1-wrapper.jar.sha256` | Apache-2.0 |
| `kernel/firmware/ath10k/QCA9377/hw1.0/notice_ath10k_firmware-sdio-5.txt` | уведомление из linux-firmware, побайтно совпадает с тегом `20260916` | тексты третьих сторон, сохраняются без изменений |
| `tools/dectest/fixtures/*.ymd5` | MD5 Y-плоскости кадров тестового ролика, снятые на приставке сопровождающего | Apache-2.0 |

## Что НЕ лежит в репозитории и как это получить

| Компонент | Почему нет в git | Как получить | Лицензия |
|---|---|---|---|
| Linux v7.1 | внешний исходник | `git clone --depth 1 --branch v7.1` stable-дерева kernel.org; коммит `8cd9520d35a6c38db6567e97dd93b1f11f185dc6` | GPL-2.0 |
| микрокод meson-vdec (`device/h96proplus/firmware/*.bin`) | бинарные блобы | `build/fetch-firmware.sh` (linux-firmware, тег `20260916`, сверка SHA-256) | `LICENSE.amlogic_vdec`: распространение разрешено для устройств на Amlogic, но не в составе ядра |
| Wi-Fi QCA9377 (`kernel/firmware/ath10k/…/*.bin`) | бинарные блобы | `build/fetch-firmware.sh` | `LICENSE.QualcommAtheros_ath10k`: распространение в двоичном виде без изменений, только с чипами Qualcomm Atheros |
| busybox для rescue | бинарный файл | `rescue/build-busybox.sh` (busybox 1.36.1, сверка SHA-256 архива) | GPL-2.0 |
| Mesa/Panfrost, libc++ (`device/h96proplus/mesa/lib64/*.so`) | результат сборки | `build/build-mesa.sh`: Mesa 24.3.0-devel и libdrm 2.4.124 из AOSP `android-15.0.0_r36`, NDK r27c; libc++ — из того же NDK | MIT (Mesa), MIT (libdrm, только для компоновки — в образе системная), Apache-2.0 WITH LLVM-exception (libc++) |
| дерево AOSP | внешний исходник | `repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r36` (коммит манифеста `a0601d2912a6cedcaf97e1372173f8704a2715b0`) | в основном Apache-2.0 |
| MovieLauncher.apk | результат сборки | `launcher/` (Gradle), см. `launcher/README.md` | Apache-2.0 |
| Monet-Launcher | у репозитория `Klevico/Monet-Launcher` нет лицензии | не входит в сборку; пользователь может поставить сам из официальных релизов | не указана — распространять нельзя |
| Google LeanbackLauncher, GApps, Google Play | проприетарные | не входят и не обещаются | проприетарные |
| SmartTube Beta и другие приложения | сторонние | только из официальных источников, самостоятельно | у каждого своя |

Если у бинарного файла не установлены происхождение и право на распространение,
он в репозиторий и в выпуски не попадает — до выяснения.
