# device/h96proplus

Конфигурация устройства AOSP для H96 Pro Plus (Amlogic S912 / Meson GXM).
Проверялась на одной плате CZ-S32-V3: фактически 2 ГиБ ОЗУ, eMMC 16 ГБ,
Ethernet RTL8211F, Wi-Fi/BT QCA9377. Надпись «3G» на наклейке не соответствует
установленной памяти. Совместимость других ревизий не проверена — см.
[STATUS.md](../../STATUS.md).

## Состав

| Файл / каталог | Назначение |
|---|---|
| `AndroidProducts.mk`, `h96proplus.mk` | продукт `h96proplus` для `lunch` |
| `BoardConfig.mk` | arm64 (cortex-a53), ядро собирается отдельно (`TARGET_NO_KERNEL`), размеры разделов, erofs для vendor |
| `device.mk` | состав системы и свойства: `zygote64`, `PRODUCT_CHARACTERISTICS := tv`, KeyMint/Gatekeeper программные |
| `fstab.emmc` | основная установка во внутреннюю eMMC (`by-name`, нужен `androidboot.boot_devices`) |
| `fstab.sdboot` | исторический профиль загрузки Android с SD (`androidboot.fstab_suffix=sdboot`) |
| `fstab.h96proplus` | ранний черновик разметки, оставлен для истории |
| `init.h96proplus.rc`, `ueventd.rc`, `watchdogd.rc` | init устройства, сторож, порядок старта служб |
| `bootwatchdog.sh` | сторож загрузки: аппаратная перезагрузка, если init завис |
| `h96-standby.sh` | снимает служебный wakelock, когда ядро умеет будиться пультом |
| `h96mouse/` | демон режима мыши: кнопка пульта, стрелки — движение, OK — клик |
| `remote/` | таблица кодов пульта (NEC), `irkeymap`, keylayout |
| `media/` | `media_codecs*.xml`, seccomp-политики Codec2 и mediaextractor |
| `mesa/Android.bp` | импорт библиотек Mesa/Panfrost; **сами .so не публикуются**, их нужно собрать (см. [DEVELOPMENT.md](../../DEVELOPMENT.md)) |
| `prebuilt-apps/` | импорт собственного MovieLauncher, APK собирается из `launcher/` |
| `firmware/` | описание и SHA-256 микрокода meson-vdec (сами .bin берутся из linux-firmware) |
| `overlay/` | ресурсы framework и SettingsProvider: питание, экран блокировки, отсутствие телефонии |
| `permissions/`, `sepolicy/`, `wifi/`, `audio/` | разрешения, политика SELinux для своих служб, Wi-Fi, аудио-политика |

## Параметры загрузчика, которые читает init

| Параметр командной строки | Значение по умолчанию | Что делает |
|---|---|---|
| `androidboot.fstab_suffix=emmc` / `sdboot` | задаётся образом | выбор fstab |
| `androidboot.h96.bootlog=1` | выключено | пишет все буферы logcat в `/data/bootlog.txt` (4×4 МиБ) — только для отладки загрузки |
| `androidboot.h96.static_ip=<IPv4>` | выключено | аварийный статический адрес eth0 (/24), только в профиле `sdboot` |

## Сеть и отладка

USB OTG на этой плате в mainline не работает (`dr_mode = "host"`), поэтому ADB
доступен только по сети, порт 5555. В публичной конфигурации ADB **требует
авторизации ключом** (`ro.adb.secure=1`): подтвердите ключ на экране телевизора
или соберите свой образ с `H96_ADB_PUBKEY=$HOME/.android/adbkey.pub`.
Сборка `userdebug` с публичными ключами AOSP (test-keys) — это сборка
разработчика, а не защищённый выпуск.

## Что изменено для публичной сборки и ещё не проверено на железе

Эти изменения внесены при подготовке открытого репозитория. Они следуют из
документированного поведения AOSP, но ни собраны, ни проверены на приставке:

1. `ro.adb.secure=1` для `userdebug`/`eng` и необязательный `PRODUCT_ADB_KEYS`.
2. POWER по умолчанию: короткое нажатие — сон (`config_shortPressOnPowerBehavior=1`),
   длинное — ничего (`config_longPressOnPowerBehavior=0`). У сопровождающего
   длинное нажатие исправлялось настройкой устройства, а прежнее значение `100`
   существовало только вместе с историческим патчем AOSP 0012, который в
   публичный ряд не входит.
3. Полный журнал загрузки и аварийный статический IP включаются только
   параметрами загрузчика (таблица выше); раньше они были жёстко включены
   и содержали адрес сети сопровождающего.
4. Домашний экран — собственный MovieLauncher вместо стороннего лаунчера
   без лицензии.
