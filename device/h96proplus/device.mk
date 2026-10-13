# device.mk — состав системы для H96 Pro Plus
#
# Список собран по docs/system-packages.md: что vendor считал нужным, что из
# этого действительно требуется TV-боксу под кино, и что AOSP тянет по
# умолчанию, а нам не нужно (ТЗ §13, §14, §31).
#
# ⚠️ ЧЕРНОВИК — уточняется на Milestone 6.

# ---------------------------------------------------------------------------
# Тип устройства
# ---------------------------------------------------------------------------
# TV-профиль вместо телефонного: другой лаунчер, D-pad-навигация,
# отсутствие телефонных сервисов.
# ⛔ core_64_bit ОБЯЗАН идти ПЕРВЫМ — до цепочки core_minimal (так велит
# комментарий в самом core_64_bit.mk: «This line must be parsed before the
# one in core_minimal.mk»).
# Без него в образ ставится ТОЛЬКО init.zygote32.rc, а наше
# ro.zygote=zygote64_32 указывает на несуществующий файл → строка
# `import /system/etc/init/hw/init.${ro.zygote}.rc` не находит ничего,
# сервис zygote не определён и НИКОГДА не стартует. Симптом: SurfaceFlinger,
# installd, mediaserver работают, дисплей включён, boot animation начата —
# но system_server не появляется, загрузка стоит вечно (попытка №13).
# ⛔ 26.08: core_64_bit → core_64_bit_ONLY (ro.zygote=zygote64).
# Причина — mediaserver. В мире zygote64_32 AOSP осознанно запускает
# 32-БИТНЫЙ mediaserver (mediaserver.zygote64_32.rc → /system/bin/
# mediaserver32) ради совместимости со старыми 32-битными кодек-плагинами.
# Но в Android 16 механизм кодеков (libapexcodecs) существует только в
# 64 битах — 32-битный mediaserver отдаёт МОЛЧА ПУСТОЙ список кодеков,
# и не работает ни один, даже программный. Чисто 64-битный мир запускает
# mediaserver64 и снимает весь пласт 32-битных проблем. Всё наше ПО
# 64-битное (SmartTube arm64-v8a, сервисы Google arm64); 32-битные
# приложения на ТВ-приставке не нужны.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_minimal.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)

PRODUCT_CHARACTERISTICS := tv

# ---------------------------------------------------------------------------
# Возможности устройства
# ---------------------------------------------------------------------------
# Wi-Fi feature пока отсутствует: интеграция не завершена (см.
# docs/wifi-bringup.md). Вернуть вместе с проверенными firmware,
# wificond и AIDL supplicant. Для STA vendor HAL в AOSP необязателен.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml \
    $(LOCAL_PATH)/permissions/tv_features.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/tv_features.xml

# Намеренно НЕ объявляем: камеру (её нет), телефонию, GPS, NFC,
# сканер отпечатков, датчики (ТЗ §14).

# ---------------------------------------------------------------------------
# Device tree
# ---------------------------------------------------------------------------
# ⛔ fstab обязан лежать В RAMDISK: first-stage init монтирует system/vendor
# ДО того, как vendor доступен — копия только в vendor/etc означает
# гарантированный не-boot. Копия в vendor/etc нужна тоже (second stage, vold).
# fstab.sdboot — вариант для загрузки с SD (M6), выбирается через
# androidboot.fstab_suffix=sdboot в bootargs (см. docs/m6-boot.md).
PRODUCT_COPY_FILES += \
    device/h96proplus/fstab.h96proplus:$(TARGET_COPY_OUT_RAMDISK)/fstab.h96proplus \
    device/h96proplus/fstab.sdboot:$(TARGET_COPY_OUT_RAMDISK)/fstab.sdboot \
    device/h96proplus/fstab.h96proplus:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.h96proplus \
    device/h96proplus/fstab.sdboot:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.sdboot

# ⛔ Device-init ОБЯЗАТЕЛЕН: без него никто не вызывает mount_all и /data
# не монтируется — система вечно висит до UI (найдено ramoops, попытка №5).
# Путь /vendor/etc/init/hw/init.${ro.hardware}.rc init загружает сам.
PRODUCT_COPY_FILES += \
    device/h96proplus/init.h96proplus.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.h96proplus.rc \
    device/h96proplus/bootwatchdog.sh:$(TARGET_COPY_OUT_VENDOR)/etc/bootwatchdog.sh \
    device/h96proplus/h96-btfix.sh:$(TARGET_COPY_OUT_VENDOR)/etc/h96-btfix.sh \
    device/h96proplus/watchdogd.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/watchdogd.rc

# ---------------------------------------------------------------------------
# Bluetooth: QCA9377 на uart_A (узел в DTS ядра, драйвер hci_qca =y).
# Прошивки rampatch/nvm — все 4 пары ROM-версий, чип сам сообщает свою
# (у нашего экземпляра 0x00230302). Путь ищется по firmware_class.path.
PRODUCT_COPY_FILES += \
    $(foreach f,$(wildcard kernel/firmware/qca/*.bin),$(f):$(TARGET_COPY_OUT_VENDOR)/firmware/qca/$(notdir $(f)))

# ⛔ Google-специфичные вендорные HCI-команды (LE_ADV_FILTER 0xfd57 и др.)
# QCA9377 не понимает; стек gd на неожиданном ответе (Unknown OpCode)
# ассертит и валит com.android.bluetooth (03.09: hci_layer.cc:234).
# С выключенными vendor capabilities стек их не шлёт — BT работает.
PRODUCT_VENDOR_PROPERTIES += \
    bluetooth.core.le.vendor_capabilities.enabled=false

# ---------------------------------------------------------------------------
# Пульт
# ---------------------------------------------------------------------------
# Раскладка и карта ИК-кодов взяты из стоковой прошивки (см. remote/README.md),
# а не подобраны экспериментально.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/remote/meson-ir.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/meson-ir.kl \
    $(LOCAL_PATH)/remote/h96proplus-nec.toml:$(TARGET_COPY_OUT_VENDOR)/etc/rc_keymaps/h96proplus-nec.toml

# ---------------------------------------------------------------------------
# Микрокод видеодекодера
# ---------------------------------------------------------------------------
# Лицензия redistributable, см. kernel/firmware/README.md.
# Сами .bin в git не коммитятся — заполнить каталог перед сборкой
# (device/h96proplus/firmware/README.md).
#
# ⚠️ gxl_hevc_mmu.bin добавлен 2026-08-16 — его в списке НЕ БЫЛО.
# Без него патч HEVC декодирует только небольшие кадры: путь с MMU нужен
# ровно для крупных, то есть для 4K, ради которого всё и затевалось.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/gxl_hevc.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_hevc.bin \
    $(LOCAL_PATH)/firmware/gxl_hevc_mmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_hevc_mmu.bin \
    $(LOCAL_PATH)/firmware/gxl_vp9.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_vp9.bin \
    $(LOCAL_PATH)/firmware/gxl_h264.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_h264.bin \
    $(LOCAL_PATH)/firmware/gxm_h264.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxm_h264.bin \
    $(LOCAL_PATH)/firmware/gxl_mpeg12.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_mpeg12.bin

# ---------------------------------------------------------------------------
# Аппаратный видеодекодер: v4l2_codec2 поверх meson-vdec
# ---------------------------------------------------------------------------
# Стек проверен по частям на прогонах 12-26 (docs/hevc-testing.md):
# драйвер декодирует h264/hevc/vp9 в 1080p и 4K бит-в-бит, работает
# stateful-протокол (SOURCE_CHANGE -> перенастройка CAPTURE ->
# DEC_CMD_STOP -> LAST) — ровно тот, которым ходит V4L2Decoder из
# external/v4l2_codec2. vdectest репетировал этот путь 1:1.
#
# Сервис ставит свой vintf-фрагмент и init.rc сам (Android.bp:
# init_rc + vintf_fragments), отдельной правки манифеста не нужно.
# SELinux: бинарь помечен mediacodec_exec (sepolicy/file_contexts),
# домен mediacodec уже hal_codec2-сервер с rw к video_device.
# Доступ к /dev/video0 группе media — ueventd.rc.
# ⛔⛔ ВОТ ПОЧЕМУ АППАРАТНЫЙ ДЕКОДЕР НЕ СОБИРАЛСЯ ВСЁ ЭТО ВРЕМЯ.
#
# В external/v4l2_codec2/Android.bp:21 объявлено `soong_namespace {}`.
# Модули внутри пространства имён НЕВИДИМЫ извне, пока продукт явно не
# объявит, что он этим пространством пользуется. Без строки ниже:
#   • файлы сборки читаются (все 9 есть в out/.module_paths/Android.bp.list);
#   • ошибок нет — пространства имён это законный механизм;
#   • но целей не создаётся ни одной:
#         ninja: unknown target 'android.hardware.media.c2@1.2-service-v4l2'
#   • PRODUCT_PACKAGES молча ни на что не влияет.
#
# Из-за этого media_codecs.xml объявлял декодеры c2.v4l2.*, которых в
# системе нет, и Android оставался БЕЗ ЕДИНОГО декодера — не работали
# даже программные (SmartTube: «неподдерживаемый формат видео и аудио»).
#
# ⚠️ Пришлось перебрать четыре неверные версии, прежде чем найти эту:
# «hidl_defaults удалён» (нет, он в hardware/interfaces/Android.bp:36),
# «молча отключается по ALLOW_MISSING_DEPENDENCIES» (не включён),
# «мешают суффиксы -32/-64», «нет vendor_available у зависимостей».
PRODUCT_SOONG_NAMESPACES += \
    external/v4l2_codec2

# libc2plugin_store обязателен вместе со службой — так требует README
# самого декодера (external/v4l2_codec2/README.md:35): без него служба
# не найдёт хранилище компонентов.
PRODUCT_PACKAGES += \
    android.hardware.media.c2@1.2-service-v4l2 \
    libc2plugin_store

# ⛔⛔ hwservicemanager — БЕЗ НЕГО ДЕКОДЕР НЕ РАБОТАЕТ, хотя и запускается.
#
# Проверено на живой приставке 24.08: служба стартует и живёт, но в журнале
#     E HidlServiceManagement: Service android.hardware.media.c2@1.2::
#       IComponentStore/default must be in VINTF manifest in order to register/get
#     E ...: Cannot register Codec2's IComponentStore service.
# и в системе остаётся только ПРОГРАММНОЕ хранилище кодеков — ровно тот
# симптом, с которого началась вся история («неподдерживаемый формат»).
#
# Сообщение обманчиво: запись в манифесте ЕСТЬ, `vintf dm` на приставке её
# показывает. Настоящая цепочка — system/libhwbinder/Utils.cpp:38:
#     isHwServiceManagerInstalled() → file_exists(".../bin/hwservicemanager")
# У нас по этому пути лежала БИТАЯ ССЫЛКА: base_system.mk ставит только
# совместимостный symlink (hwservicemanager_compat_symlink_module), а сам
# диспетчер приходит из base_system_ext.mk, которого в продукте нет. Проверка
# идёт ПО ССЫЛКЕ, цели не существует → ложь → подставляется NoHwServiceManager
# (ServiceManagement.cpp:374), у которого getTransport() всегда возвращает
# Transport::EMPTY (строка 237), а add() отказывает со словами «Cannot add …
# without hwservicemanager» (строка 224). Регистрация HIDL становится
# невозможной в принципе — независимо от манифеста.
#
# ⚠️ ИСПРАВЛЕНИЕ ПРЕЖНЕГО ВЫВОДА (ниже по файлу, у gralloc). Там было сказано:
# «Android 16 выпилил hwservicemanager, HIDL-сервисы не регистрируются в
# принципе». Симптом описан верно, ПРИЧИНА неверна: ничего не выпиливали,
# диспетчер просто не собирался в наш продукт. Выбор AIDL для gralloc и
# прочих HAL при этом остаётся правильным и ничего не теряет.
#
# ⚠️ Альтернативы нет: у v4l2_codec2 ТОЛЬКО HIDL-служба, AIDL-варианта в
# external/v4l2_codec2 не существует (проверено grep по Android.bp).
#
# ⚠️ ЗА ЧЕМ СЛЕДИТЬ: waitForHwServiceManager() ждёт свойство
# hwservicemanager.ready БЕСКОНЕЧНО (Utils.cpp:54). Если диспетчер окажется
# установлен, но не запустится, любой процесс с libhidl повиснет намертво.
# Запуск безусловный — system/core/rootdir/init.rc:450.
# ⛔⛔ НЕ ВОЗВРАЩАТЬ hwservicemanager — ОН ЛОМАЕТ ЗАГРУЗКУ.
#
# Проверено дважды 24.08: с ним приставка НЕ ЗАГРУЖАЕТСЯ. Успевает поднять
# сам диспетчер (hwservicemanager.ready=true) и 64-битную службу декодера,
# после чего загрузка встаёт и сторож уводит приставку в сток. Журнала не
# остаётся — система не доходит даже до запуска логгера.
#
# Механизм (версия, прямых доказательств в журнале нет): пока диспетчера не
# было, libhidl подставлял NoHwServiceManager, и ВСЕ обращения к HIDL
# проваливались МГНОВЕННО — в журнале рабочей загрузки таких десятки:
#     Cannot list manifest for android.hardware.keymaster@4.1::IKeymasterDevice
#     Trying to get transport of android.system.suspend@1.0::ISystemSuspend
#     ... configstore@1.0::ISurfaceFlingerConfigs, camera.provider@2.4, netd@1.1
# С настоящим диспетчером те же обращения начинают ЖДАТЬ службы, которых у
# нас нет (мы везде на AIDL). То есть быстрый отказ превратился в вечное
# ожидание. Особенно опасен `wait_for_keymaster` в post-fs-data: init на нём
# блокируется, и дальше не выполняется НИЧЕГО — ни наши команды, ни adbd.
#
# ✅ ПРАВИЛЬНЫЙ ПУТЬ — не чинить HIDL, а уйти от него. Платформа уже целиком
# на AIDL: программное хранилище кодеков регистрируется как
# `android.hardware.media.c2.IComponentStore/software` (без номера версии —
# это AIDL). Значит и службу декодера надо перевести на AIDL, см. патч
# aosp-patches/0005. Обёртки HIDL и AIDL принимают ОДНО И ТО ЖЕ
# `C2ComponentStore`, поэтому подмена прямая; образец — сам AOSP,
# frameworks/av/media/codec2/hal/services/vendor.cpp, функция runAidlService().

# ---------------------------------------------------------------------------
# ИК-пульт
# ---------------------------------------------------------------------------
# Загрузчик таблицы кнопок (в Android нет ir-keytable) + сама таблица,
# измеренная на живом пульте владельца, + все раскладки из стоковой
# прошивки «Франкенштейн».
# ⚠️ Коды в таблице НЕ совпадают с remote.conf прошивки: там описан пульт
# с адресом 0x4040, а реальный шлёт 0x01. Приставки продаются с разными
# пультами — верить надо замеру, а не конфигурации из образа.
PRODUCT_PACKAGES += \
    irkeymap \
    h96mouse

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/remote/h96-remote.map:$(TARGET_COPY_OUT_VENDOR)/etc/h96-remote.map \
    $(LOCAL_PATH)/remote/meson-ir.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/h96-remote.kl \
    $(LOCAL_PATH)/remote/remote.conf:$(TARGET_COPY_OUT_VENDOR)/etc/remote.conf \
    $(LOCAL_PATH)/apply-max-performance.sh:$(TARGET_COPY_OUT_VENDOR)/etc/apply-max-performance.sh

# Раскладки клавиш из стоковой прошивки: штатный ИК-пульт, геймпады,
# USB-клавиатуры и мыши, пульты Bluetooth.
PRODUCT_COPY_FILES += \
    $(foreach kl,$(wildcard $(LOCAL_PATH)/remote/keylayout/*.kl),\
        $(kl):$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/$(notdir $(kl)))

# ---------------------------------------------------------------------------
# Конфигурация аудио — ОБЯЗАТЕЛЬНА, иначе система не грузится
# ---------------------------------------------------------------------------
# ⛔ Попытка №21: system_server вечно висел в AudioService.<init> →
# setLowRamDevice → ожидание AudioFlinger, и его убивал сторож Android
# («Blocked in handler on main thread for 68s»). Причина цепочкой:
#   audio_effects_config.xml отсутствовал → vendor.audio-effect-hal-aidl
#   выходил с кодом 1 → его `onrestart restart audioserver` поднимал бурю
#   взаимных перезапусков audioserver ↔ audio-HAL каждые 5 секунд →
#   AudioFlinger никогда не регистрировался.
# Плюс сам HAL читает audio_policy_configuration.xml
# (audio_get_audio_policy_config_file) — без него не создаются модули.
#
# Берём ГОТОВЫЙ ТВ-профиль AOSP (generic_tv) — он включает по xi:include
# primary_tv, usb, r_submix, громкости и surround; все они копируются
# рядом, иначе парсер не соберёт документ.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration_7_0.xml \
    frameworks/av/services/audiopolicy/config/stub_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/stub_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/primary_audio_policy_configuration_tv.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration_tv.xml \
    frameworks/av/services/audiopolicy/config/usb_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/usb_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    frameworks/av/services/audiopolicy/config/surround_sound_configuration_5_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/surround_sound_configuration_5_0.xml \
    hardware/interfaces/audio/aidl/default/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/media_codecs.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs.xml \
    $(LOCAL_PATH)/media/media_codecs_performance.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_performance.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_c2_video.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_google_c2_video.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_c2_audio.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_google_c2_audio.xml \
    $(LOCAL_PATH)/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# ⛔ 26.08, развязка «пустого списка кодеков» — ДВЕ строки ниже обязательны.
#
# 1. media.c2.hal.selection=aidl. Codec2Client при построении списка кодеков
#    выбирает транспорт по HalSelection.cpp: без этого свойства — HIDL, а
#    hwservicemanager у нас удалён, и клиент честно писал «No Codec2
#    services declared in the manifest» при живых, зарегистрированных
#    сторах. Свойство обязано стоять С САМОЙ ЗАГРУЗКИ: media.swcodec читает
#    его на старте и при hidl-выборе регистрирует AIDL-стор ПУСТЫШКОЙ
#    (CodecServiceRegistrant: H2C2ComponentStore(nullptr), «listComponents
#    -- not supported») — поздний setprop чинит только вновь запущенные
#    процессы, пустышка остаётся до перезапуска media.swcodec.
PRODUCT_VENDOR_PROPERTIES += \
    media.c2.hal.selection=aidl

# 2. Дополнение seccomp-политики v4l2-сервиса. Базовая политика v4l2_codec2
#    писалась под старый ChromeOS-мир и не знает eventfd2 — а его зовёт
#    libchrome MessagePump при старте потока декодера. minijail убивал
#    сервис SIGSYS ровно в MediaCodec::start (лог: «blocked syscall:
#    eventfd2»), клиент видел «Codec2 component died». Файл подхватывается
#    сервисом сам: kExtSeccompPolicyPath в service.cpp.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/android.hardware.media.c2-extended-seccomp_policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/android.hardware.media.c2-extended-seccomp_policy

# media.extractor uses libcutils memfd on the mainline kernel (no ashmem).
# main_extractorservice.cpp merges this vendor extension into its APEX policy.
# Keep minijail enabled; the diagnostic tombstone shows SIGSYS on memfd_create.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/mediaextractor.policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/mediaextractor.policy

# 3. Микрокод декодера. В bring-up он жил в initramfs тестового ядра, а в
#    Android-образ не попадал вовсе: первый же QBUF стартовал сессию, ядро
#    искало meson/vdec/gxl_*.bin, получало ENOENT — и вход отвергался
#    (26.08, «Direct firmware load ... failed with error -2»). Файлы из
#    LibreELEC/meson-firmware (SHA256 — kernel/firmware/README.md). Ядро
#    ищет в /vendor/firmware благодаря firmware_class.path в cmdline
#    (make-android-sd.sh) — mainline само этот путь НЕ знает.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/meson-vdec/gxl_h264.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_h264.bin \
    $(LOCAL_PATH)/firmware/meson-vdec/gxl_hevc.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_hevc.bin \
    $(LOCAL_PATH)/firmware/meson-vdec/gxl_hevc_mmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_hevc_mmu.bin \
    $(LOCAL_PATH)/firmware/meson-vdec/gxl_mpeg12.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_mpeg12.bin \
    $(LOCAL_PATH)/firmware/meson-vdec/gxl_vp9.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxl_vp9.bin \
    $(LOCAL_PATH)/firmware/meson-vdec/gxm_h264.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/meson/vdec/gxm_h264.bin

# ---------------------------------------------------------------------------
# Графика (аудит 2026-08-18, docs/m5-graphics.md)
# ---------------------------------------------------------------------------
# Связка целиком снята с device/linaro/dragonboard — единственной платы в
# этом дереве с тем же стеком (KMS + drm_hwcomposer + minigbm):
#
#   композитор  com.android.hardware.graphics.composer.drm_hwcomposer —
#               vendor-APEX с AIDL-сервисом hwc3 (rc и vintf внутри);
#   gralloc     HIDL gralloc4 minigbm, generic-флейвор: DRV_MESON в коде
#               не используется нигде, а INIT_DUMB_DRIVER(meson) в
#               dumb_driver.c безусловный — узел KMS «meson» подхватится
#               и без отдельного флейвора (линейные dumb-буферы);
#   GLES        ⚠️ ВРЕМЕННО ANGLE поверх программного Vulkan (SwiftShader
#               vulkan.pastel). Panfrost-Mesa в AOSP НЕ собирается:
#               external/mesa3d умеет генерить soong только для turnip,
#               dragonboard берёт Mesa готовым пакетом Linaro. Наш путь к
#               GPU — кросс-сборка Mesa 24.2 (panfrost) в prebuilt, задача
#               заведена в m5-graphics.md. UI на 8×A53 в софте — только
#               для оживления M6, кино это не касается: декодер аппаратный.
# ⛔ gralloc — ТОЛЬКО AIDL. (Причина уточнена 24.08: раньше здесь стояло
# «Android 16 выпилил hwservicemanager» — это НЕВЕРНО, он просто не ставился
# в продукт, разбор выше у PRODUCT_PACKAGES += hwservicemanager. Сообщение
# «hwservicemanager is not supported on the device» выдаёт libhidl, когда не
# находит файл диспетчера. Сам выбор AIDL остаётся правильным.) SurfaceFlinger искал IAllocator/default (AIDL),
# не находил и падал в SkiaGLRenderEngine::create (попытка №11).
PRODUCT_PACKAGES += \
    com.android.hardware.graphics.composer.drm_hwcomposer \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \
    mapper.minigbm.xml \
    libEGL_angle \
    libGLESv1_CM_angle \
    libGLESv2_angle \
    vulkan.pastel

# SwiftShader-у нужен исполняемый heap под JIT (как у dragonboard/swangle)
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

# 04.09.2026: Mali ВКЛЮЧЕНА (egl=mesa). UI на Mali-T820/Panfrost (GLES 3.1),
# загрузка ~90 с. В этой сборке не работал импорт NV12-буферов декодера
# в GPU-композицию, поэтому видео идёт аппаратным underlay-планом VD1, а НЕ
# через SkiaRenderEngine. Чтобы это заработало без чёрного видео и рестарта SF:
#   1) SkiaRenderEngine/GaneshBackendTexture — мягкий пропуск несъедобных
#      (NV12) слоёв вместо LOG_ALWAYS_FATAL (system-new1, патчи frameworks);
#   2) drm_hwcomposer (aosp-patches/0009): на meson RGB-слои всегда client
#      (полноэкранный target -> плоскость OSD, у которой atomic_check требует
#      full-CRTC), только YUV-видео -> плоскость VD1; флаттенинг отключён,
#      иначе на паузе/статике видео-плоскость гасла и видео чернело.
# Откат: вернуть ro.hardware.egl=angle (библиотеки angle тоже в vendor).
# Panfrost power-transition timeouts требуют отдельной проверки runtime PM.
# Не считать их косметикой без замера; см. docs/reports/2026-09-06-stability-fixes.md.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.gralloc=minigbm \
    ro.hardware.egl=mesa \
    ro.hardware.vulkan=pastel \
    debug.hwui.renderer=skiagl

# Сами библиотеки Mesa (mesa/Android.bp, собирает build/build-mesa.sh).
# Модули там только объявлены — без этого списка сборка их не ставит, и
# vendor остаётся без драйвера, хотя ro.hardware.egl=mesa ищет libEGL_mesa.
# У сопровождающего пропуск не был виден: библиотеки попадали в vendor
# пересадкой файлов в готовый образ. Нашла его полная сборка по
# DEVELOPMENT.md (13.10.2026). Образец — device/linaro/dragonboard/shared/
# graphics/mesa/device.mk.
PRODUCT_PACKAGES += \
    libEGL_mesa \
    libGLESv1_CM_mesa \
    libGLESv2_mesa \
    libgallium_dri \
    libglapi \
    libc++_shared_mesa

# ⛔ ЦВЕТОВАЯ МАТРИЦА — НЕ ЧЕРЕЗ ПРОЦЕССОР (30.08.2026).
#
# По умолчанию drm_hwcomposer работает в режиме DRM_OR_GPU: если драйвер
# дисплея не умеет применять цветовую матрицу, её применяет GPU. А раз
# «GPU» здесь программный, это означает, что ЛЮБОЙ слой объявляется
# клиентским (backend/Backend.cpp, IsClientLayer -> CtmByGpu), аппаратные
# плоскости не используются вовсе, и каждый кадр видео собирается
# процессором. Замер на живой системе: surfaceflinger 629% CPU,
# meson_overlay_plane пуст, из 1418 кадров показаны 448.
#
# Драйвер meson свойства CTM не имеет и иметь не будет. Указываем
# «не умеешь — не применяй»: цветокоррекция приставке не нужна, а
# видеоплоскость освобождает шесть ядер и выводит кадр без пересчёта.
PRODUCT_VENDOR_PROPERTIES += \
    vendor.hwc.drm.ctm=DRM_OR_IGNORE \
    vendor.hwc.drm.use_overlay_planes=1 \
    vendor.hwc.drm.scale_with_gpu=0

# МНОЖИТЕЛЬ ТАЙМАУТОВ — ключ к жизни на программном рендере (25.08.2026).
#
# Приставка уходила в перезагрузочную петлю: SystemUI не успевал стартовать,
# сторож Android убивал system_server. Первая попытка лечения — патч
# Watchdog.java (60 -> 300 с) — оказалась НЕВЕРНОЙ: разбор с проверкой
# скептиками показал, что SystemUI умирает не по сторожу, а по таймауту
# старта приложения (BIND_APPLICATION_TIMEOUT = 15 c, продление максимум
# вдвое и один раз), и как persistent-процесс после ANR-убийства
# перезапускается вечно, сжигая процессор.
#
# ro.hw_timeout_multiplier умножает ВСЕ системные таймауты согласованно:
#   сторож 60->300 с, старт приложения 15-30 -> 75-150 с, PROC_START 10->50,
#   SERVICE_TIMEOUT 20->100, BROADCAST 10/60 -> 50/300, WMS BOOT 30->150 с.
# Ровно так лечит ту же болезнь апстримный AOSP-продукт fvpbase с тем же
# стеком ANGLE-поверх-SwiftShader (goldfish/fvpbase/fvp.mk ставит 50).
#
# ПРОВЕРИТЬ ЧЕРЕЗ setprop НЕЛЬЗЯ: sepolicy запрещает менять это свойство
# всем, кроме init (neverallow hw_timeout_multiplier_prop) — только отсюда.
# Когда заработает настоящий GPU (задача M5b) — убрать вместе с прочими
# послаблениями: с множителем настоящий взаимоблок ищется в 5 раз дольше.
PRODUCT_VENDOR_PROPERTIES +=     ro.hw_timeout_multiplier=5


# SurfaceFlinger требует плотность («ro.sf.lcd_density must be defined»).
# 320 — стандарт ТВ-приставок на 1080p.
PRODUCT_VENDOR_PROPERTIES += \
    ro.sf.lcd_density=320

# ---------------------------------------------------------------------------
# Остальные HAL
# ---------------------------------------------------------------------------
# ⛔ Тоже только AIDL (hwservicemanager-а нет, HIDL-версии мертвы).
# Аудио — ТОЛЬКО через APEX: сам бинарь помечен `installable: false,
# // installed in apex com.android.hardware.audio`, поэтому прямой
# PRODUCT_PACKAGES на него ничего не устанавливает (проверено: в
# vendor/bin/hw пусто). Так же его берёт cuttlefish.
# health — обязателен даже без батареи: BatteryService в startCoreServices
# кидает исключение без IHealth/default, system_server умирает (попытка №18).
# example-сервис сам сообщает «батареи нет», rc+vintf несёт с собой,
# метка на точное имя «…-service.example» уже в базовой политике.
# power — обязателен: HintManagerService в startOtherServices падает NPE
# на SupportInfo без IPower/default (попытка №19, подтверждено логом).
# power.stats — в паре, как у dragonboard. Метки на точные имена — в базе.
PRODUCT_PACKAGES += \
    com.android.hardware.audio \
    android.hardware.bluetooth-service.default \
    android.hardware.health-service.example \
    android.hardware.power-service.example \
    android.hardware.power.stats-service.example \
    com.android.hardware.thermal

# ⛔ Wi-Fi HAL ОТКЛЮЧЁН до M7. При BOARD_WLAN_DEVICE=qcwcn собирается
# вариант libwifi-hal под закрытый QCOM-стек, которому нужен libcld80211
# (в AOSP его нет): «CANNOT LINK EXECUTABLE ... library libcld80211.so
# not found». Сервис падал раз в 5 секунд, а после 4 падений init
# перезагружал систему («process with updatable components exited 4
# times before boot completed») — попытка №13 умерла именно так.
# Для описанного QCA9377 SDIO выбран ath10k+nl80211. Начать с STA без
# необязательного vendor HAL; supplicant HAL всё равно нужен.
# Не раскомментировать падающий qcwcn-вариант. См. docs/wifi-bringup.md.
# PRODUCT_PACKAGES += android.hardware.wifi-service

# ✅ 09.09.2026 Wi-Fi STA без vendor HAL: ath10k_sdio (встроен) + nl80211 +
# wificond (уже в system) + AIDL wpa_supplicant (vendor, /vendor/bin/hw).
# Модуль wpa_supplicant `proprietary` и через `required` тянет VINTF-фрагмент
# android.hardware.wifi.supplicant.xml; init rc подключается только при
# soong_config wpa_supplicant_8.wifi_hidl_unified_supplicant_service_rc_entry
# (имя историческое, сам rc — AIDL: aidl/vendor/android.hardware.wifi.supplicant-service.rc).
PRODUCT_PACKAGES += \
    wpa_supplicant
$(call soong_config_set,wpa_supplicant_8,wifi_hidl_unified_supplicant_service_rc_entry,true)

# ⛔ 12.09.2026: `wpa_supplicant.conf` в PRODUCT_PACKAGES ЛОМАЛО сборку:
#   FAILED: ninja: unknown target 'wpa_supplicant.conf', did you mean 'wpa_supplicant.conf.cf'?
# Цели с таким именем в этой конфигурации НЕТ — блок в
# external/wpa_supplicant_8/wpa_supplicant/Android.mk, который её определял, закомментирован
# вверх по течению. module-info.json модуль всё равно перечисляет (там путь установки
# vendor/etc/wifi/wpa_supplicant.conf) — это ложный след, ninja отвергает и имя, и путь.
# Шаблон конфига кладём копированием: supplicant ищет его по /vendor/etc/wifi/wpa_supplicant.conf
# (kVendorTemplateConfPath в supplicant.cpp).
PRODUCT_COPY_FILES += \
    external/wpa_supplicant_8/wpa_supplicant/wpa_supplicant.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant.conf

# WifiNative берёт имя интерфейса из wifi.interface (fallback wlan0).
PRODUCT_VENDOR_PROPERTIES += \
    wifi.interface=wlan0

# Firmware QCA9377 SDIO для ath10k (имена — ровно те, что просит драйвер:
# firmware-sdio-N.bin, board-2.bin, board.bin; см. kernel/firmware/ath10k/.../MANIFEST.txt).
# Явные файлы, а не wildcard: отсутствие обязательного файла ломает сборку.
H96_ATH10K_FW := kernel/firmware/ath10k/QCA9377/hw1.0
$(foreach f,firmware-sdio-5.bin board-2.bin board.bin,\
  $(if $(wildcard $(H96_ATH10K_FW)/$(f)),,$(error Missing required ath10k firmware $(H96_ATH10K_FW)/$(f))))
PRODUCT_COPY_FILES += \
    $(H96_ATH10K_FW)/firmware-sdio-5.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath10k/QCA9377/hw1.0/firmware-sdio-5.bin \
    $(H96_ATH10K_FW)/board-2.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath10k/QCA9377/hw1.0/board-2.bin \
    $(H96_ATH10K_FW)/board.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath10k/QCA9377/hw1.0/board.bin \
    $(H96_ATH10K_FW)/notice_ath10k_firmware-sdio-5.txt:$(TARGET_COPY_OUT_VENDOR)/firmware/ath10k/QCA9377/hw1.0/notice_ath10k_firmware-sdio-5.txt

# Встроенный ath10k_sdio пробует прошивку на ~2 с — до монтирования /vendor
# (firmware_class.path=/vendor/firmware) → -2. Ограниченная повторная привязка
# только обнаруженной Wi-Fi SDIO-функции после готовности vendor (on post-fs).
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/h96-wifi-rebind.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/h96-wifi-rebind.rc

# Утилиты, без которых неудобно отлаживать на месте.
# v4l2-ctl в AOSP нет (v4l-utils не в manifest) — свой vdectest уже в паре
# к нему не нуждается; при нужде утилита ставится adb-пушем.
PRODUCT_PACKAGES += \
    ethtool \
    iperf3


# ---------------------------------------------------------------------------
# Свойства системы
# ---------------------------------------------------------------------------
# Только то, что подтверждается исходниками AOSP. Никаких «твиков» из
# интернета (ТЗ §17).
# ro.opengles.version: пока GLES отдаёт ANGLE поверх SwiftShader — заявляем
# ES 3.0 (196608), как dragonboard/swangle. С переходом на Panfrost (T820 =
# ES 3.2) поднять до 196610.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware=h96proplus \
    ro.board.platform=gxm \
    ro.opengles.version=196608 \
    ro.zygote=zygote64 \
    persist.sys.usb.config=adb

# ADB authentication in every build variant. Network ADB on port 5555 is the
# only ADB path on this board (init.h96proplus.rc), and AOSP itself sets
# ro.adb.secure=1 only for 'user' builds: a userdebug/eng build would accept
# ANY host on the network without a key. Public-release change, not yet
# build- or hardware-tested (see STATUS.md).
ifneq ($(TARGET_BUILD_VARIANT),user)
PRODUCT_SYSTEM_PROPERTIES += ro.adb.secure=1
endif
# Optional: pre-authorise YOUR OWN host key in YOUR OWN image, e.g.
#   H96_ADB_PUBKEY=$HOME/.android/adbkey.pub m
# Never commit a key file to this repository.
ifneq ($(H96_ADB_PUBKEY),)
PRODUCT_ADB_KEYS := $(H96_ADB_PUBKEY)
PRODUCT_PACKAGES += adb_keys
endif

# ---------------------------------------------------------------------------
# Криптохранилище — ПРОГРАММНЫЕ KeyMint и Gatekeeper (TEE не используем)
# ---------------------------------------------------------------------------
# ⛔ Без KeyMint система НЕ ГРУЗИТСЯ ДО UI, а висит «на пингвинах»:
# keystore2 крашится в цикле («Cannot connect to Keymint /
# HARDWARE_TYPE_UNAVAILABLE»), vold вечно ждёт android.security.maintenance
# и не отдаёт /data (ramoops попытки №4, 19.08). Оба сервиса несут свои
# vintf-фрагменты сами; hardware_keystore.xml объявляет фичу.
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service.nonsecure \
    com.android.hardware.gatekeeper.nonsecure \
    android.hardware.hardware_keystore.xml

# ⚠️ ТОЛЬКО ДЛЯ BRING-UP (M6): adb по Ethernet. USB-gadget в ядре не собран,
# так что USB-adb недоступен физически; критерий M6 «загрузка до adb»
# достигается по сети: adb connect <ip>:5555. Убрать перед релизом.
PRODUCT_PROPERTY_OVERRIDES += \
    service.adb.tcp.port=5555

# ⚠️ BRING-UP: постоянный logcat на /data/misc/logd — постмортем-диагностика
# зависаний читается со снятой карты/из стока. Убрать перед релизом.
PRODUCT_PROPERTY_OVERRIDES += \
    persist.logd.logpersistd=logcatd \
    persist.logd.logpersistd.size=64

# Телефонии нет. Здесь раньше стояло свойство ro.radio.noril — пустое
# заклинание: во всём дереве Android его никто не читает. Реально
# телефонию выключают три вещи: оверлей config_voice_capable и соседние
# (overlay/frameworks/base/.../config.xml), объявление возможностей
# отсутствующими (permissions/tv_features.xml) и стаб-пакет
# H96NoTelephony, вычёркивающий телефонные приложения из образа.

# Стаб-пакет, вычёркивающий телефонные приложения из образа (см.
# notelephony/Android.bp — там подробно, что именно уходит и почему нельзя
# трогать библиотеки загрузочного класспуса).
# ⚠ 30.08: стаб-пакет ВРЕМЕННО отключён. После его добавления система
# перестала загружаться (ядро стартует, Android до сети не доходит).
# Подозрение на вычёркивание TelephonyProvider и BlockedNumberProvider:
# к первому обращается системный сервер при старте, от второго зависит
# поставщик контактов. Возвращать по одному пакету после того, как
# причина будет подтверждена сохранённым логом ядра.
# PRODUCT_PACKAGES += H96NoTelephony

# ⛔⛔ ОБЯЗАТЕЛЬНО ДЛЯ MAINLINE-ЯДРА: разделяемая память через memfd.
# libcutils (ashmem-dev.cpp) по умолчанию ходит в /dev/ashmem — драйвер
# Android-специфичный, в mainline его НЕТ ВООБЩЕ (в GKI он подгружается
# модулем ashmem_linux). Без этого свойства system_server падает сразу
# после старта: «RuntimeException: Failed to create ashmem: No such file
# or directory» в ApplicationSharedMemory.nativeCreate → зигота умирает,
# бесконечный цикл перезапуска (попытка №14).
# Второе условие (ro.treble.enabled=true) у нас уже выполнено.
# Ядро проверено: MFD_NOEXEC_SEAL и F_SEAL_FUTURE_WRITE поддерживаются.
# ⚠️ Именно PRODUCT_SYSTEM_PROPERTIES, а не PRODUCT_PROPERTY_OVERRIDES:
# последний кладёт свойство в /vendor/build.prop, откуда его ставит
# vendor_init — а тому запрещено трогать use_memfd_prop
# («avc: denied { set } for property=sys.use_memfd scontext=vendor_init»,
# попытка №15). Из /system/build.prop свойство ставит init, которому можно.
PRODUCT_SYSTEM_PROPERTIES += \
    sys.use_memfd=true

# ⛔ 26.08: RescueParty дважды за утро перезагрузил живую систему:
# сессию B — за крэш-петлю com.google.android.gms.persistent (NPE в
# GservicesProvider, GMS 23.48 на Android 16), сессию C — за гибель
# system_server об отсутствующий вторичный zygote. Вторая причина
# починена в BoardConfig.mk, первая (GMS) пока не разобрана — а до тех
# пор каждый persistent-процесс с петлёй превращается в перезагрузку
# всей приставки. На bring-up перезагрузками занимается bootwatchdog,
# RescueParty только мешает диагностике (уносит систему до того, как
# успеваешь снять логи). Убрать вместе со сторожем перед релизом.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.disable_rescue=true

# ---------------------------------------------------------------------------
# Перекрытия ресурсов: экран никогда не гаснет и не блокируется
# ---------------------------------------------------------------------------
# Каталог overlay/ повторяет структуру дерева AOSP. Механизм статический:
# значения вшиваются в framework-res.apk и SettingsProvider на сборке.
# Обоснование каждого значения — в комментариях внутри самих файлов
# (там же разобрано, почему -1 из порта Amlogic давал бы 10 секунд).
DEVICE_PACKAGE_OVERLAYS += device/h96proplus/overlay

# Третий рубеж отключения блокировки, читается в DatabaseHelper.java:2206.
# Как и def_lockscreen_disabled, заполняет Settings.System.LOCKSCREEN_DISABLED
# (в Android 16 наследие) — стоит здесь ради полноты, вреда нет.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.lockscreen.disable.default=true

# ---------------------------------------------------------------------------
# Размеры кучи Java
# ---------------------------------------------------------------------------
# ⛔⛔ БЕЗ ЭТОГО СИСТЕМА ПАДАЕТ ЦИКЛАМИ, КОГДА СТОЯТ СЕРВИСЫ GOOGLE.
#
# У нас эти свойства не задавались НИ РАЗУ: продукт собран из core_minimal +
# aosp_base, а профиль кучи в AOSP подключается отдельным файлом, который
# мы не наследовали. ART тогда берёт встроенное умолчание —
# `kDefaultMaximumSize = 256 * MB` (art/runtime/gc/heap.h:141).
#
# Пока сервисов Google не было, 256 МБ system_server хватало. С ними база
# пакетов выросла, и 23.08 приставка пошла вразнос:
#     E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: OomAdjuster
#     java.lang.OutOfMemoryError: Failed to allocate a 48 byte allocation
#         with 161104 free bytes and 157KB until OOM
#     I system_server: Waiting for a blocking GC Alloc
# (падали также batterystats-handler и BackgroundInstallControlService).
# Каждое падение system_server утаскивало все приложения
# (DeadSystemException), а в итоге срабатывал RescueParty и перезагружал
# приставку — «reboot: Restarting system with command 'RescueParty'».
# ⚠️ Свободной ОЗУ при этом было ~900 МБ: кончалась не память приставки,
# а жёсткий лимит виртуальной машины.
#
# Значения — штатный профиль AOSP для устройств с 2 ГБ
# (frameworks/native/build/tablet-10in-xhdpi-2048-dalvik-heap.mk), тот же,
# что наследует официальный порт Amlogic (yukawa/device-common.mk:45).
# heapsize=512m — потолок system_server; heapgrowthlimit=192m — потолок
# обычных приложений, чтобы одно приложение не съело всё.
PRODUCT_VENDOR_PROPERTIES += \
    dalvik.vm.heapstartsize=16m \
    dalvik.vm.heapgrowthlimit=192m \
    dalvik.vm.heapsize=512m \
    dalvik.vm.heaptargetutilization=0.75 \
    dalvik.vm.heapminfree=512k \
    dalvik.vm.heapmaxfree=8m

# Локали: только нужные. AOSP по умолчанию тянет десятки (ТЗ §31).
PRODUCT_LOCALES := ru_RU en_US

# ---------------------------------------------------------------------------
# Лаунчер
# ---------------------------------------------------------------------------
# Public builds: the home screen is the project's own MovieLauncher
# (launcher/, Kotlin, no permissions, no network). Build it BEFORE the image
# so that prebuilt-apps/MovieLauncher.apk exists — see launcher/README.md.
#
# History (maintainer's unit, not a public build input): from 2026-08-31 the
# maintainer used Monet-Launcher 1.0.76 (github.com/Klevico/Monet-Launcher).
# That repository publishes no licence, so its APK is neither redistributed
# nor referenced here; install it yourself after first boot if you want it.
# Google's LeanbackLauncher 2016 build is proprietary and is not used either.
#
# Launcher3QuickStep from the base AOSP profile crash-looped on this TV build
# (31 restarts, NullPointerException in WidgetManagerHelper: no widget service),
# so MovieLauncher overrides it in prebuilt-apps/Android.bp. APKs cannot go
# through PRODUCT_COPY_FILES ("use BUILD_PREBUILT instead"), hence
# android_app_import.
H96_HOME_LAUNCHER ?= MovieLauncher
PRODUCT_PACKAGES += \
    $(H96_HOME_LAUNCHER)

# ⛔ Без этой строки устройство уйдёт в bootloop, а не просто «не выдаст
# разрешение»: system_server бросает IllegalStateException в onSystemReady().
# Подробности и ссылка на код AOSP — в самом файле.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/permissions/privapp-permissions-h96proplus.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/privapp-permissions-h96proplus.xml

# Экранная клавиатура: берём ИЗ AOSP (packages/inputmethods/LeanbackIME,
# targetSdk 33), а не стоковую 2015 года с targetSdk 23 — та ниже порога
# Android 15 и собрана под давно изменившийся IME-контракт.
PRODUCT_PACKAGES += \
    LeanbackIME
