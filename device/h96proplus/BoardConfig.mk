# BoardConfig.mk — H96 Pro Plus (Amlogic S912 / Meson GXM)
#
# Ключевые значения СНЯТЫ С ЖИВОГО УСТРОЙСТВА 2026-08-16: размеры разделов,
# объём памяти, чип Wi-Fi. Подробности — out/device-info-*/FINDINGS.md.
#
# Остальное подтверждено разбором установленной прошивки и её DTB —
# см. docs/stock-image-analysis.md.

# ---------------------------------------------------------------------------
# Платформа
# ---------------------------------------------------------------------------
TARGET_BOARD_PLATFORM := gxm
TARGET_BOOTLOADER_BOARD_NAME := h96proplus

# 64-битная сборка. Сток был 32-битным (ro.zygote=zygote32), но это выбор
# vendor, а не ограничение железа: S912 — восемь ядер ARMv8.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a53

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := cortex-a53

# ⛔ 26.08: TARGET_SUPPORTS_32_BIT_APPS ОБЯЗАН быть false в 64-битном мире.
# Из него собирается ro.product.cpu.abilist32; если список непуст,
# system_server на boot_completed стучится во ВТОРИЧНЫЙ zygote
# (ZygoteProcess.bootCompleted: «if SUPPORTED_32_BIT_ABIS.length > 0»),
# которого при ro.zygote=zygote64 не существует, — RuntimeException,
# гибель system_server, четыре повтора и перезагрузка RescueParty
# (сессия C, dropbox system_server_crash@1787736383373). TARGET_2ND_ARCH
# оставлен: 32-битные библиотеки собираются, но приложениям не предлагаются.
TARGET_SUPPORTS_32_BIT_APPS := false
TARGET_SUPPORTS_64_BIT_APPS := true

# ---------------------------------------------------------------------------
# Ядро
# ---------------------------------------------------------------------------
# Дерево ядра живёт вне AOSP: kernel/config/h96proplus_defconfig в этом
# репозитории, сборка через scripts/build/build-kernel.sh.
#
# TARGET_NO_KERNEL := true — ядро AOSP-сборке НЕ отдаём, и это осознанно:
# 1) boot.img из AOSP всё равно не используется — kernel.img пакует
#    make-android-sd.sh (abootimg, свои адреса, см. docs/m6-boot.md);
# 2) с пребилтом ядра check_vintf сверял бы «kernel 7.1» с матрицей
#    совместимости Android 16 (знает максимум 6.12) — падение сборки;
# 3) без него сборка №7 требовала $(PRODUCT_OUT)/kernel и падала:
#    «'out/.../kernel' missing and no known rule to make it».
# ramdisk.img при этом собирается как обычно.
TARGET_NO_KERNEL := true
BOARD_KERNEL_IMAGE_NAME := Image

# Адреса — из заголовка стокового boot.img (abootimg -i), не выдуманные.
BOARD_KERNEL_BASE      := 0x01078000
BOARD_KERNEL_OFFSET    := 0x00008000
BOARD_RAMDISK_OFFSET   := 0x00000000
BOARD_KERNEL_TAGS_OFFSET := 0x00000100
BOARD_KERNEL_PAGESIZE  := 2048

# У стока cmdline пуст — параметры передаёт U-Boot. Для отладки своей сборки
# консоль указываем явно.
BOARD_KERNEL_CMDLINE := console=ttyAML0,115200 earlycon

# ---------------------------------------------------------------------------
# Разделы — ✅ СНЯТЫ С УСТРОЙСТВА 2026-08-16
# ---------------------------------------------------------------------------
# Источник: /proc/device-tree/partitions на живой системе.
# ⚠️ `by-name` на этой прошивке ОТСУТСТВУЕТ — привычный способ
#     ls -l /dev/block/by-name
# не работает, разметку пришлось брать из device-tree.
#
# Реальная таблица (сверена с /proc/partitions):
#     boot      32 МиБ     rsv        8 МиБ
#     recovery  32 МиБ     tee        8 МиБ
#     logo      32 МиБ     cache    512 МиБ
#     misc      32 МиБ     system     2 ГиБ
#     crypt     32 МиБ     data     остаток (~11,7 ГиБ)
#
# eMMC: 15 634 268 160 байт (14,56 ГиБ) + boot0/boot1 по 4 МиБ + rpmb.

BOARD_BOOTIMAGE_PARTITION_SIZE     := 33554432    # 32 МиБ  ✅ с устройства
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 33554432    # 32 МиБ  ✅
BOARD_SYSTEMIMAGE_PARTITION_SIZE   := 2147483648  # 2 ГиБ   ✅
BOARD_CACHEIMAGE_PARTITION_SIZE    := 536870912   # 512 МиБ ✅

# ⚠️ system = 2 ГиБ — это потолок, заданный текущей разметкой. Android 15
# заметно крупнее семёрки, и если образ не влезет, есть два пути:
#   1) урезать состав (docs/system-packages.md) — предпочтительно;
#   2) переразметить eMMC, забрав у data — но это ломает совместимость
#      со стоковым образом и усложняет откат.
# Начинаем с первого.

# ⛔ system/vendor — EROFS, и это НЕ вкусовщина.
# Пока они были ext4, стоковый Android при каждой своей загрузке монтировал
# их с SD как «съёмный носитель» и рекурсивно перекрашивал SELinux-метки
# в mnt_media_rw_file. Наш init после этого падал на первой же стадии
# (avc denied для pid=1, reboot в bootloader — попытки №3 и №7).
# MBR-тип 0xDA не помог: этот vold определяет ФС по содержимому.
# EROFS появился в ядре 5.4 — Android 7.1 со своим 3.14 его не смонтирует
# физически. Бонусом: образ втрое меньше и read-only по природе.
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE  := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_FLASH_BLOCK_SIZE := 4096

# lz4hc: ядро с CONFIG_EROFS_FS_ZIP=y умеет его без дополнительных опций.
# ⚠️ БЕЗ кавычек: они уезжают в soong.variables как есть и ломают JSON
# («invalid character 'l' after object key:value pair»).
BOARD_EROFS_COMPRESSOR := lz4hc,9

# Vendor-образ. Без этих строк vendor.img НЕ создаётся вовсе: HAL-ы и
# микрокод молча лягут в $(PRODUCT_OUT)/vendor и ни в один образ не попадут.
# В стоковой разметке раздела vendor нет — на M6 он живёт на SD-карте,
# для eMMC решается переразметкой на M12 (см. docs/m6-boot.md).
TARGET_COPY_OUT_VENDOR := vendor
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDORIMAGE_PARTITION_SIZE := 536870912   # 512 МиБ, с запасом

TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# ---------------------------------------------------------------------------
# Память
# ---------------------------------------------------------------------------
# ✅ ПРОВЕРЕНО НА УСТРОЙСТВЕ 2026-08-16: памяти 2 ГБ, а не 3.
#     dmesg: Memory: 1439712K/2092032K available, 652320K reserved
#     amlogic-dt-id = gxm_q201_2g   ← загрузчик сам определил 2 ГБ
# Наклейка на плате "CZ 3G+16G" действительности не соответствует.
# Исходное ТЗ было право, мой вывод по multi-DTB образа — ошибочен.
#
# При 2 ГБ вопрос low-RAM режима перестаёт быть очевидным. Пока НЕ включаем:
# Android 15 с zygote64_32 на 2 ГБ работоспособен, а low-RAM урезает
# функциональность (нет recents-миниатюр, ограничен многозадачный кэш).
# Решение окончательно принимается на M11 по замерам.
MALLOC_SVELTE := false

# ZRAM. У vendor 500 МиБ (fstab.amlogic: zramsize=524288000) — при 2 ГБ это
# уже около четверти памяти. Оставляем столько же, уточняем на M11 (ТЗ §18).
BOARD_ZRAM_SIZE := 536870912

# ---------------------------------------------------------------------------
# Графика
# ---------------------------------------------------------------------------
# Panfrost + Mesa вместо закрытого mali.ko из стока.
BOARD_GPU_DRIVERS := panfrost
TARGET_USES_HWC2 := true
NUM_FRAMEBUFFER_SURFACE_BUFFERS := 3

# ---------------------------------------------------------------------------
# Сеть
# ---------------------------------------------------------------------------
# ✅ ОПРЕДЕЛЁН НА УСТРОЙСТВЕ: SDIO 0271:0701 = Qualcomm Atheros QCA9377.
# В mainline — ath10k_sdio (CONFIG_ATH10K_SDIO), firmware из linux-firmware
# (ath10k/QCA9377/hw1.0/). Vendor использовал проприетарный ar6k_wlan.
# 09.09.2026: BOARD_WLAN_DEVICE := qcwcn СНЯТ — он выбирал проприетарный
# QCOM-стек (libwifi-hal под libcld80211, которого в AOSP нет). Штатный
# STA-путь: ath10k + nl80211 + wificond + AIDL wpa_supplicant без vendor HAL.
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
BOARD_HOSTAPD_DRIVER := NL80211

# Bluetooth в стоке идёт по UART (CONFIG_BT_HCIUART_H4 в вендорском ядре).
BOARD_HAVE_BLUETOOTH := true

# ---------------------------------------------------------------------------
# Чего на этом устройстве нет
# ---------------------------------------------------------------------------
# Телефония выключается в device.mk (оверлей + tv_features.xml + стаб-пакет).
# Переменной TARGET_NO_RADIO в системе сборки не существует вовсе — есть
# только TARGET_NO_RADIOIMAGE, а прежняя строка была заклинанием без эффекта.
BOARD_HAVE_CAMERA := false

# ---------------------------------------------------------------------------
# VINTF
# ---------------------------------------------------------------------------
# Без манифеста check_vintf_vendor валит сборку на 97% (№9: 19 часов).
# В manifest.xml — только HAL-ы без своих vintf_fragments (audio, bt);
# gralloc/wifi/c2 самодекларируются, composer — внутри APEX.
DEVICE_MANIFEST_FILE := device/h96proplus/manifest.xml

# ---------------------------------------------------------------------------
# SELinux
# ---------------------------------------------------------------------------
# На время отладки — permissive, финальный образ обязан быть enforcing
# (ТЗ §35). Оставлять permissive в релизе нельзя.
BOARD_SEPOLICY_DIRS += device/h96proplus/sepolicy

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_FSTAB := device/h96proplus/fstab.h96proplus

# ⛔⛔ ТОЧКА /metadata — без неё НЕ РАБОТАЕТ НИ ОДИН КОДЕК (найдено 25.08).
#
# Симптом, с которого началась вся история: SmartTube «неподдерживаемый
# формат», screenrecord «unable to create video/avc codec instance»,
# «Decoder infos by media types:» пуст. Чистый лог падающего процесса
# показал 17 подряд ошибок:
#     aconfig_cpp_codegen: failed to open
#         /metadata/aconfig/maps/system.package.map
# и сразу «ScreenRecord: failed». Нативный код кодеков Android 16 читает
# aconfig-флаги; Java-обвязка ошибку чтения глотает (валится в дефолты),
# а нативная — НЕТ: создание любого кодека, даже программного, падает.
#
# Отдельный РАЗДЕЛ на карте не нужен: этот флаг лишь создаёт ТОЧКУ
# /metadata в корне (system/core/rootdir/create_root_structure.mk:64,
# «ifdef» — само значение не важно), а наш init.h96proplus.rc монтирует
# туда tmpfs на early-init. Дальше всё делает ШТАТНЫЙ aconfigd.rc: его
# секция «on post-fs» создаёт /metadata/aconfig/* и запускает
# system_aconfigd_platform_init, который заполняет карты флагов заново на
# каждой загрузке. Персистентность флагов нам не нужна — мы их не крутим.
BOARD_USES_METADATA_PARTITION := true

# ⛔⛔ 64-БИТНЫЙ MEDIASERVER — без него список кодеков МОЛЧА ПУСТ (26.08).
#
# После починки /metadata кодеки всё равно не создавались, причём без
# единой строки жалоб. strace показал: клиент список не строит — получает
# по binder от mediaserver; сам mediaserver ЧИТАЕТ все media_codecs*.xml
# успешно — и всё равно отдаёт пустоту, а перед этим не находит
#     /system/lib/libapexcodecs.so → ENOENT
# Эта библиотека нового механизма кодеков Android 16 существует ТОЛЬКО в
# 64-битном виде (/apex/com.android.media.swcodec/lib64/). Наш mediaserver
# собрался 32-битным, потому что этого флага не было. ВСЕ 64-битные
# референсные платы AOSP его ставят (build/make/target/board/gsi_arm64,
# generic_arm64, generic_x86_64, generic_riscv64) — то есть 32-битный
# mediaserver на arm64 в Android 16 просто не является поддерживаемой
# конфигурацией.
TARGET_DYNAMIC_64_32_MEDIASERVER := true
