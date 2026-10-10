> ⚠️ **Про `watchdog.open_timeout` в командной строке ядра.** Было `600`,
> стало **`0`**. С ненулевым значением ядро кормит аппаратный сторож
> ровно столько секунд и, если userspace не открыл `/dev/watchdog`,
> СБРАСЫВАЕТ SoC — так оборвалась попытка №23 уже ПОСЛЕ успешной
> загрузки. Я предполагал, что сторож перехватит штатный `watchdogd`,
> но в образе AOSP есть только бинарь, а описания службы нет ни в одном
> rc-файле (добавлено в `device/h96proplus/watchdogd.rc`).
> При `0` ядро (`watchdog_dev.c`: `open_deadline = open_timeout ? … :
> KTIME_MAX`) кормит сторож бесконечно, пока его не заберёт userspace —
> внезапных сбросов быть не может, а `watchdogd` при этом всё равно
> может взять управление.

# Патчи к дереву AOSP

**Какие патчи применять и в каком порядке, определяет только реестр
[`series.json`](series.json)** — не номера файлов. Здесь есть исторические
и заменённые патчи: например, 0012 (Android shutdown по короткому POWER) в
публичный ряд не входит — полное выключение на этой плате приводило к
перезапуску, а принятая конфигурация использует сон
(см. [HISTORY.md](../HISTORY.md)).

Правки не в `device/h96proplus/`, а в самом AOSP; после свежего `repo sync`
их накладывают вручную. Накладываются только патчи со статусом `active` из
`series.json`, каждый в своём каталоге `apply_in` (`.` — корень AOSP):

```bash
cd "$AOSP_ROOT/external/minigbm" && git apply --check "$REPO/aosp-patches/0001-minigbm-drop-drm-master.patch" \
    && git apply "$REPO/aosp-patches/0001-minigbm-drop-drm-master.patch"
```

Модуль `external/v4l2_codec2` заменяется целиком из `aosp-overlay/` — патчи
0005, 0007, 0011, 0013, 0017 и 0018 уже в нём и повторно не накладываются;
их описания ниже объясняют, как модуль пришёл к этому состоянию.

## 0001 — minigbm отдаёт DRM-мастера

**Симптом:** экран не менялся ни в одной из 20 попыток — на HDMI
навсегда оставалась консоль ядра («пингвины»), хотя Android грузился.

```text
drmhwc: DRM/KMS master access required
drmhwc: No pipelines available. Creating null-display for headless mode
```

**Причина:** у Amlogic GXM дисплей (`meson`, card1) и GPU (`panfrost`)
— разные DRM-устройства, у дисплейного нет render-узла. minigbm обязан
открыть первичный узел, а первый открывший молча становится DRM-мастером.
rc аллокатора (`/vendor/etc/init/allocator.rc`) парсится раньше rc
композитора (внутри APEX), поэтому аллокатор всегда успевал первым.

**Фикс:** `drmDropMaster()` сразу после `open()`. Мастер аллокатору не
нужен — в ядре 7.1 `DRM_IOCTL_MODE_CREATE_DUMB` объявлен с флагами `0`
(`drm_ioctl.c:696`), без DRM_MASTER/DRM_AUTH. Безопасен при любом
порядке старта: у не-мастера вызов просто вернёт ошибку.

⚠️ Обратный путь невозможен: `drm_setmaster_ioctl` отдаёт мастера лишь
тому, кто им уже был или имеет `CAP_SYS_ADMIN` (у сервиса только
`SYS_NICE`), и при живом чужом мастере возвращает `EBUSY`.

## 0002 — libcutils: memfd, когда /dev/ashmem нет

**Симптом:** `system_server` падал сразу после старта —
`RuntimeException: Failed to create ashmem: No such file or directory`
в `ApplicationSharedMemory.nativeCreate`.

**Причина:** ashmem удалён из mainline-ядра (5.18+), в GKI его везут
модулем `ashmem_linux`. libcutils по умолчанию идёт в `/dev/ashmem`, а
путь через memfd закрыт свойством `sys.use_memfd` (по умолчанию false).
Само свойство выставить не удалось: из `vendor/build.prop` его ставит
`vendor_init`, которому sepolicy это **запрещает** явным neverallow
(`system/sepolicy/public/property.te:112`), а из `system/build.prop`
оно до процесса не доезжало.

**Фикс:** если `/dev/ashmem` отсутствует — использовать memfd
безусловно, альтернативы всё равно нет. Поведение на ядрах с ashmem не
меняется, свойство там по-прежнему уважается.


## 0003 — soong пропускает предел памяти Go

**Зачем.** `soong_ui` запускает `soong_build` с ПУСТЫМ окружением: в
`ui/build/soong.go` создаётся `invocationEnv := make(map[string]string)`,
куда кладут только `GODEBUG` и только в отладочном режиме, и он же уходит
в `Env` при запуске. Поэтому обычный `export GOMEMLIMIT=…` до процесса не
доходит вовсе — проверяется одной командой:

```
tr '\0' '\n' < /proc/$(pgrep -x soong_build)/environ | grep GO
```

Я дважды подбирал эти значения в разные стороны (12GiB/GOGC=50, потом
60GiB/GOGC=200) и оба раза «наблюдал эффект», которого быть не могло.

**Почему это важно именно здесь.** Машина сборки — 4 ядра и 24 ГБ
(см. память `host-build-pc-wsl`). Без предела куча Go разрастается вдвое
от живых данных и доходит до ~30 ГБ: 12,5 ГБ в ОЗУ плюс 17,5 ГБ в
подкачке. Замер 23.08 в этом состоянии: `si` 36 МБ/с, `so` 71 МБ/с,
ожидание диска 44%, полезная работа 9%, а у Windows остаётся 870 МБ
доступной памяти — ровно то состояние, с которого в 19:53 начиналось
зависание всего компьютера.

**Что делает патч.** Пропускает два значения через `SOONG_`-префикс:

| переменная оболочки | что получает soong_build |
|---|---|
| `SOONG_GOMEMLIMIT` | `GOMEMLIMIT` |
| `SOONG_GODEBUG`    | `GODEBUG`    |

Отладочная ветка soong по-прежнему может перебить `GODEBUG` — она идёт
ниже по коду, и это правильно.

**Как применять.** `SOONG_GOMEMLIMIT=10GiB` при виртуалке в 14 ГБ.
`SOONG_GODEBUG=gctrace=1` печатает после каждой уборки «было->пик->стало
МБ»; третье число — живая куча. Если она подбирается к пределу, доля
времени в сборщике (второе число строки) полезет вверх — тогда предел
поднимать, но уже по цифрам, а не наугад.


## 0005 — v4l2_codec2: служба на AIDL и только 64-битная

Заменяет прежний патч 0004 (он вошёл сюда целиком).

### Часть первая: только 64-битная служба

Оба файла запуска, которые ставит модуль, объявляют службу с ОДНИМ И ТЕМ ЖЕ
именем `android-hardware-media-c2-v4l2-hal-1-2`, но с разными бинарниками.
Init оставляет разобранное последним — 32-битное, — и оно немедленно умирает:

```
libminijail: nonexistent syscall 'mmap' / 'getrlimit' / 'newfstatat'
libminijail: blocked syscall: mmap2
```

Единственный установленный файл ограничений системных вызовов написан под
64 бита; на 32-битном ARM это `mmap2`, `ugetrlimit`, `fstatat64`, строки
отбрасываются, `mmap2` в разрешённые не попадает. Итог — вечный перезапуск, а
64-битная служба не стартует ни разу. Лечится `compile_multilib: "first"`.

### Часть вторая: переход с HIDL на AIDL — главная

**Симптом.** 64-битная служба, запущенная вручную, живёт, но пишет
`Cannot register Codec2's IComponentStore service`.

**Почему.** HIDL на этой сборке мёртв: `hwservicemanager` не собирался в
продукт, а `libhidl` без него подставляет `NoHwServiceManager`, у которого
`getTransport()` всегда `EMPTY`, а `add()` отказывает.

**⛔ Доставить hwservicemanager — НЕ решение, проверено дважды: приставка
перестаёт загружаться.** Пока диспетчера не было, все обращения к HIDL
проваливались МГНОВЕННО (в журнале десятки строк про `keymaster`,
`ISystemSuspend`, `configstore`, `camera.provider`, `netd`). С настоящим
диспетчером те же обращения начинают ЖДАТЬ службы, которых в системе нет —
быстрый отказ превращается в вечное ожидание.

**Решение.** Платформа и так целиком на AIDL: программное хранилище кодеков
регистрируется как `android.hardware.media.c2.IComponentStore/software` (без
номера версии — признак AIDL). Патч переводит на AIDL и нашу службу:

| что | было | стало |
|---|---|---|
| заголовки | `codec2/hidl/1.2/ComponentStore.h` | `codec2/aidl/ComponentStore.h` + `binder_manager/process` |
| пул потоков | `configureRpcThreadpool` | `ABinderProcess_*` |
| регистрация | `registerAsService("default")` | `AServiceManager_addService(…"/default")` |
| манифест | `format="hidl"`, `@1.2::IComponentStore/default` | `format="aidl"`, `IComponentStore/default` |
| Android.bp | — | `libcodec2-aidl-defaults`, `libbinder_ndk` |

Подмена прямая: обёртки HIDL и AIDL принимают ОДИН И ТОТ ЖЕ
`std::shared_ptr<C2ComponentStore>` (`codec2/aidl/ComponentStore.h:62`).
Образец — сам AOSP: `frameworks/av/media/codec2/hal/services/vendor.cpp`,
функция `runAidlService()`.

Имя `default` выбрано не произвольно: клиент перечисляет ОБЪЯВЛЕННЫЕ
экземпляры через `AServiceManager_forEachDeclaredInstance` и сортирует по
префиксу `default` → `vendor` → прочие (`codec2/hal/client/client.cpp:2356`).
Без записи в манифесте служба останется невидимой, даже работая.

## 0015 — размер картинки: проекция дисплея вместо оверскана

Файл: `0015-framework-display-size-percent.patch`. Трогает два файла в
`frameworks/base/services/core/java/com/android/server/display/`.

**Зачем.** Телевизор срезает края. `wm size` и `wm density` меняют логический
дисплей, но картинка всё равно растягивается на всю панель; преобразование
только в UI оставляет видео под ним в полный размер; у mainline-драйвера
`meson` нет свойства DRM `underscan` — проверено в дереве, его там нет.

**Куда встроено.** `LogicalDisplay.configureDisplayLocked()` вычисляет
прямоугольник панели, в который отображается логический дисплей, и передаёт
его в `DisplayDevice.setProjectionLocked()` → `setDisplayProjection()`. Это
**проекция дисплея**, а не преобразование окна, поэтому SurfaceFlinger
применяет её ко всем слоям дисплея — включая те, что композитор кладёт на
собственные плоскости.

Патч ужимает этот прямоугольник вокруг его же центра. Прямоугольник уже
отцентрован, так что центр и соотношение сторон сохраняются.

**Почему это не ломает 0009.** Клиентская цель остаётся размером с дисплей
(`RenderSurface::mSize` берётся из `setDisplaySize()`, а не из проекции):
внутрь неё слои рисуются со сдвигом, вокруг — чёрное поле. Первичная
плоскость OSD по-прежнему покрывает весь CRTC, чего требует
`meson_plane_atomic_check()` (`DRM_PLANE_NO_SCALING`, `can_position = false`).

**Почему видео едет вместе с интерфейсом.** `meson_overlay_atomic_check()`
вызывает `drm_atomic_helper_check_plane_state()` с `FRAC_16_16(1, 5)` …
`FRAC_16_16(5, 1)` и `can_position = true` — плоскость VD1 допускает
уменьшение до 1/5 и свободное положение. 80–100 % лежат внутри этого.

**Почему курсор остаётся на месте.** `DisplayDevice.populateViewportLocked()`
заполняет `viewport.physicalFrame` из `mCurrentDisplayRect` — того самого
прямоугольника. Ввод проходит через то же отображение, второй раз нигде не
применяется.

**Два параметра, а не один:**

| ключ `Settings.Secure` | смысл |
|---|---|
| `screen_size_percent` | подтверждённый размер; читается при загрузке, переживает перезагрузку |
| `screen_size_percent_preview` | размер, который сейчас примеряют; 0 или отсутствие = никакого |

Пока предпросмотр есть, он побеждает. Он стирается при загрузке и снимается
службой дисплея через 20 с, если Settings перестал его подтверждать. Право
вернуть размер лежит на службе дисплея, а не на приложении, которое могло
упасть. Settings обновляет предпросмотр каждые 5 с, его собственный диалог
идёт 15 с — то есть обычно пользователь видит отсчёт приложения, а сторож
ядра системы срабатывает только если приложения не стало.

Значение вне 80…100 или нечисловое читается как 100 с обеих сторон.
`handleLogicalDisplayAddedLocked()` заново применяет подтверждённый размер,
когда основной дисплей появляется, — поэтому переподключение HDMI не
возвращает картинку молча в полный размер.

Физический режим не трогается: в этом пути нет вызова
`setDesiredDisplayModeSpecs()`, вывод остаётся 1920×1080 на своей частоте.

## 0016 — SurfaceFlinger падал на пропавшем дисплее из-за строки журнала

Файл: `0016-surfaceflinger-null-buffer-guards-writeBufferStateToHWC.patch`. Трогает
`frameworks/native/services/surfaceflinger/CompositionEngine/src/OutputLayer.cpp`,
функцию `writeBufferStateToHWC()`. В нём две правки; первая уже была в установленном
двоичном файле (сборка 03.09), вторая — новая.

**Как найдено.** Надгробия на приставке: `signal 11 (SIGSEGV)`, `fault addr 0x70`,
кадр `#00 … OutputLayer::writeStateToHWC(...)+1776`. Идентификатор сборки
`bed1c1d3f574754d8e0fdc8427c0327f` совпадает с
`out/target/product/h96proplus/symbols/system/bin/surfaceflinger`, поэтому смещение
разрешается точно:

```
0x3cc420 -> OutputLayer::writeBufferStateToHWC(...)   OutputLayer.cpp:855:9
         -> writeOutputIndependentPerFrameStateToHWC  OutputLayer.cpp:726:13
         -> writeStateToHWC                           OutputLayer.cpp:489:5
```

**Что там на самом деле.** Строка 855 — это `ALOGE` в ветке ошибки `setBuffer()`:

```c
if (auto error = hwcLayer->setBuffer(slotAndBuffer.slot, slotAndBuffer.buffer, fence);
    error != hal::Error::NONE) {
    ALOGE("[%s] Failed to set buffer %p: %s (%d)", getLayerFE().getDebugName(),
          slotAndBuffer.buffer->handle, ...);     // <- разыменование
}
```

А `HwcBufferCache.h` прямо говорит: *«In cases where the buffer is already cached, the
buffer is a nullptr and will not be sent to HWC as an optimization»*, и
`getHwcSlotAndBuffer()` при попадании в кэш возвращает `{cache.slot, nullptr}` — то
есть **nullptr здесь штатное значение, а не признак ошибки**.

Сойтись должны оба условия: буфер уже в кэше HWC (обычное дело для установившегося
воспроизведения) **и** `setBuffer()` вернул ошибку. Второе происходит ровно тогда,
когда дисплея уже нет — `BAD_DISPLAY` после неудачного hotplug. Поэтому вместо записи
об ошибке SurfaceFlinger разыменовывал ноль и падал, унося с собой всю графику.
Это объясняет серию падений с одной и той же сигнатурой.

**Правка.** Строка журнала больше не предполагает наличие буфера:

```c
slotAndBuffer.buffer ? slotAndBuffer.buffer->handle : nullptr
```

Поведение вне ветки ошибки не меняется ни на байт.

**Чего патч не делает.** Он не чинит сам неудачный hotplug и не утверждает, что
причина того — выключенный телевизор. Он убирает то, что превращало сообщение об
ошибке в падение всего сервера отображения.


## 0017 — v4l2_codec2: повтор всей серии CSD (SPS+PPS) после flush

**Симптом:** в SmartTube (DASH/MP4 avc1, YouTube AVC) КАЖДАЯ перемотка
замораживала картинку на ~20 с, после чего приложение само пересоздавало
плеер. Владелец описывал это как «паузы примерно раз в минуту».

**Причина:** правка 0008 повторяла после flush только ПОСЛЕДНИЙ
CODEC_CONFIG-блок (`mLastCsd`). Для `avc1` фреймворк отдаёт SPS и PPS
ДВУМЯ отдельными CSD-работами (csd-0, csd-1), поэтому повторялся один
PPS. Драйвер meson-vdec на STREAMOFF CAPTURE делает полный teardown
прошивки; свежий микрокод получал PPS и слайсы, но без SPS не поднимал
`CMD_SRC_CHANGE`, не программировал канвасы/`AV_SCRATCH_0` и молча не
декодировал. Парсер при этом ES проглатывал (отсюда `onDecodeDone OK` при
нуле кадров на выходе). Подтверждено на боксе: kernel-`h96 h264
src_change` не появлялся ни после одного из повторов, только когда
SmartTube строил новый кодек.

**Фикс:** копить ВСЕ блоки текущей серии CSD
(`std::vector<C2ConstLinearBlock> mCsdRun`) и повторять их после flush в
исходном порядке — ровно та стартовая последовательность, которую
прошивка принимает. Ядро не трогается; совместимо с 0017/0018/0025/0027
(ядро) и 0029 (звук). Замерено: 5 перемоток — 0 перезапусков движка, 0 с
простоя декодера (было ~20 с + перезапуск на каждую). Живёт в
`libv4l2_codec2_components.so` (партиция vendor).

## 0019 — drm_hwcomposer не должен уничтожать дисплей при hotplug

**Симптом:** после ухода монитора в ждущий режим (и при подключении экрана
уже после загрузки без него) SurfaceFlinger печатал `Failed to hotplug
display 0` и дальше — шторм `Invalid display` около 1200 сообщений в
секунду, картинка не возвращалась до перезагрузки. Владелец описывал это
как «приставка не загружается, если телевизор не подключён».
(Исходный журнал наблюдения хранится в закрытом журнале сопровождающего.)

**Причина:** `DrmHwcThree::HandleDisplayHotplugEvent()` вычёркивал объект
`HwcDisplay` из `DrmHwc::displays_` прямо во время *оповещения* о hotplug.
Эти объекты принадлежат `DrmHwc`, их жизнь задаётся
`BindDisplay()`/`UnbindDisplay()`/`FinalizeDisplayBinding()`; удаление здесь
уничтожает дисплей за спиной владельца: `display_handles_` по-прежнему
указывает на handle 0, в `displays_` его уже нет, `GetDisplay()` отдаёт
null и любой следующий вызов HWC3 отвечает `BAD_DISPLAY (2)`.

Срабатывало и при отключении, и при КАЖДОМ подключении после первого:
`HwcDisplay::SetPipeline()` всегда планирует `kConnected` для основного
дисплея (SurfaceFlinger делает `LOG_ALWAYS_FATAL`, если основной объявить
отключённым), а `AddPhysicalDisplay()` вызывается только отсюда — значит
после первого объявления `HasDisplay(0)` истинно навсегда.

**Фикс:** убрать удаление, оставив учёт кэша буферов
(`RemoveDisplay`/`AddPhysicalDisplay`). В upstream drm_hwcomposer этот блок
удалён целиком. `CleanDisplayResources()` намеренно больше не вызывается на
пути повторного объявления: он начинается с `SetPowerMode(OFF)`, который —
раз дисплей теперь выживает — реально погасил бы DPMS только что собранный
`SetPipeline()` конвейер; его работа с кэшем избыточна, потому что
`SetPipeline()->Deinit()` уже отпустил client target, а `RemoveDisplay()`
сбрасывает кэш. Стратегия композиции не тронута, так что YUV-оверлей и
полноэкранный RGB client target из 0009 в силе.

Живёт в `vendor/apex/com.android.hardware.graphics.composer.drm_hwcomposer.apex`
(sha256 `4d65af97…`, было `50acec62…`); внутри образа APEX отличается ровно
один файл — `bin/hw/android.hardware.composer.hwc3-service.drm`.
