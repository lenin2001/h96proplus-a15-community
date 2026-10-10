# Патчи HEVC для meson-vdec (Milestone 13)

Здесь лежит серия, возвращающая аппаратное декодирование H.265 на GXM/S912.
Файлы сохранены из архива рассылки **до начала работ** — архивы имеют
свойство пропадать, а это ключевой актив всего Milestone 13.

```text
0000-cover-letter.txt                                       сопроводительное письмо автора
0001-meson-vdec-implement-10bit-bitstream-handling.patch    26 556 байт
0002-meson-vdec-add-HEVC-decode-codec.patch                 54 117 байт
```

```text
sha256(0001) = 42ac5aa2585570ec85a228c7f33aefc9705900c0333e7b19a66a2fc3c7e2a356
sha256(0002) = ac11656857230fc8dc1068614d794375541bf5905261e859c18a09b37c5a022a
```

---

## Происхождение

```text
Серия      : [PATCH v3 0/2] media: meson: vdec: add HEVC decode codec
Дата       : 2023-03-14
Отправил   : Christian Hewitt <christianshewitt@gmail.com>  (LibreELEC/CoreELEC)
Автор кода : Maxime Jourdan <mjourdan@baylibre.com>          (автор самого meson-vdec)
Доработка  : Benjamin Roszak <benjamin545@gmail.com>
База       : git://linuxtv.org/media_tree.git master (~v6.2-rc)
Patchwork  : https://patchwork.linuxtv.org/series/10073/
Message-Id : 20230314114318.4057353-1-christianshewitt@gmail.com
Статус     : changes-requested — в апстрим не принят
```

Родословная важна: это не самодельный патч со стороны, а код автора
оригинального драйвера `meson-vdec`, доведённый и переотправленный
разработчиком LibreELEC.

---

## Что делает

### 0001 — обработка 10-битного битстрима

```text
8 файлов, +161 / −97
```

Формально «подготовительный рефакторинг»: протаскивает битность через общий
код, `amvdec_src_change()` получает дополнительный аргумент.

#### ⚠️ Но это не только рефакторинг — он переписывает работающий VP9

В `codec_h264.c` изменение действительно косметическое:

```c
-  amvdec_src_change(sess, frame_width, frame_height, h264->max_refs + 5);
+  amvdec_src_change(sess, frame_width, frame_height, h264->max_refs + 5, 8);
```

А вот в `codec_vp9.c` меняется логика работы с памятью:

```c
-  sz = amvdec_am21c_body_size(w, h);
+  sz = amvdec_amfbc_body_size(w, h, vp9->is_10bit, use_mmu);
```

плюс переработан выбор адреса заголовка FBC (`HEVC_CM_HEADER_START_ADDR`
теперь берётся либо из MMU-таблицы, либо напрямую из буфера, в зависимости от
downsample) и добавлен расчёт `use_mmu` по ревизии платформы.

**Почему это важно именно нам.** VP9 — единственный кодек, который даёт 4K на
GXM в mainline **уже сейчас, без всяких патчей**. Ошибка в этом рефакторинге
означает: мы меняем работающую функцию на неработающую.

Отсюда обязательный порядок тестирования:

```text
1. Снять эталон VP9 ДО применения патчей   ← контрольная точка
2. Применить патчи
3. Проверить, что VP9 не деградировал      ← если сломался, дальше HEVC не идём
4. Только потом заниматься HEVC
```

Регрессия VP9 — цена, которую платить нельзя: без HEVC прошивка остаётся
рабочей, без VP9 теряется 4K на YouTube.

### 0002 — сам декодер

```text
6 файлов, +1517 / −2
create mode 100644 drivers/staging/media/meson/vdec/codec_hevc.c   (1463 строки)
create mode 100644 drivers/staging/media/meson/vdec/codec_hevc.h   (13 строк)
```

Регистрация формата в `vdec_platform.c` — для трёх платформ, **включая нашу**:

```c
/* добавляется в vdec_formats_gxbb, vdec_formats_gxl И vdec_formats_gxm */
.pixfmt        = V4L2_PIX_FMT_HEVC,
.max_width     = 3840,
.max_height    = 2160,
.firmware_path = "meson/vdec/gxl_hevc.bin",
.pixfmts_cap   = { V4L2_PIX_FMT_NV12M, 0 },
```

То есть 4K заявлен для GXM явно, выход NV12M.

---

## Почему серия не была принята — разбор

Это главный вопрос перед началом M13: заглохла она из-за принципиальных
возражений или просто потому, что автор перестал её вести?

**Возражений по существу не было, и к v3 не осталось ни одного открытого
замечания.** Полный список за все три ревизии:

| Ревизия | Кто | Замечание | Статус |
|---|---|---|---|
| v1 | kernel test robot | предупреждение о неиспользуемой переменной | ✅ исправлено в v2 |
| v2 | Dan Carpenter (smatch) | `codec_hevc_prepare_new_frame()` — утечка `new_frame` | ✅ **исправлено в v3** |
| v3 | Hans Verkuil (мейнтейнер media) | «не вижу этой firmware в пакетах — она вообще есть в linux-firmware?» | ✅ разрешено, см. ниже |

Это подтверждается и сопроводительным письмом v3
([`0000-cover-letter.txt`](0000-cover-letter.txt)):

```text
Changes from v2:
- fix memory leak reported by smatch
Changes from v1:
- Fix unused val warning reported by kernel test robot
```

и самим кодом — в нашей копии в `codec_hevc_prepare_new_frame()` уже стоит
`kfree(new_frame)` на пути ошибки:

```c
vbuf = v4l2_m2m_dst_buf_remove(sess->m2m_ctx);
if (!vbuf) {
        dev_err(sess->core->dev, "No dst buffer available\n");
        kfree(new_frame);     /* ← исправление из v3 */
        return NULL;
}
```

Ответ Christian Hewitt на замечание Hans Verkuil: firmware апстримнута
Maxime в 2019 и обновлена в 2020. Проверено — так и есть:

```text
linux-firmware / WHENCE:
  Driver: meson-vdec - Amlogic video decoder
  File: meson/vdec/gxl_hevc.bin        ← ровно то, что просит патч
  File: meson/vdec/gxl_hevc_mmu.bin
  Licence: Redistributable. See LICENSE.amlogic_vdec for details.
```

Ни архитектурных претензий, ни «так делать нельзя», ни отказа мейнтейнера.
Серия просто осталась без сопровождающего.

---

## ⚠️ Что автор говорит о качестве сам

Это важнее замечаний рецензентов — и это то, чего не видно из diff'а.
Прямые цитаты из [`0000-cover-letter.txt`](0000-cover-letter.txt):

### 1. Драйвер сознательно отправлен «как есть», с известными багами

> The goal of upstreaming the driver in its current state is to encourage
> greater community contribution towards adding missing features, and fixing
> the **bugs and conformance issues** necessary to get out of staging.

То есть это не готовый продукт, а «база, на которой можно работать». Часть
отладки на GXM ляжет на нас.

### 2. 10-bit падает на новых SoC — а GXM включён

> Only GXBB/GXL/GXM are enabled as decoding currently **crashes on G12A and
> later SoCs when trying to decode a 10-bit HEVC stream**.

Наш GXM в списке включённых. Но крах именно на 10-bit у соседнего поколения —
повод не считать 10-bit на GXM работающим, пока не проверено на железе.
8-bit — основная цель, 10-bit — бонус.

### 3. ⛔ Драйверу нужен доработанный клиент V4L2 — риск №1 для M13

> The HEVC codec presented here is generally partnered with **FFMpeg sources
> that are being maintained by the Raspberry Pi Foundation** that contain
> numerous improvements to v4l2_m2m (and v4l2_request) support.

Это самое серьёзное практическое ограничение. Драйвер отлаживался в связке
со специальной сборкой FFmpeg, а не со стандартным клиентом V4L2. Для нас
это значит: **даже заработавший в ядре декодер может не завестись через
`external/v4l2_codec2` в Android** без доработок на стороне клиента.

Отсюда порядок проверки в M13 — сначала убедиться, что декодер вообще
работает, вне Android:

```text
1. v4l2-ctl / GStreamer v4l2h265dec на голом Linux   ← сначала это
2. FFmpeg от RPi Foundation, если стандартный не тянет
3. только потом мост Codec2 в Android
```

Дойти до пункта 1 и остановиться — уже результат: он отвечает на вопрос,
работает ли железо, отдельно от вопроса, работает ли интеграция с Android.

### Родственные ветки, если понадобится сверка

```text
оригинал Maxime Jourdan : github.com/Elyotna/linux  ветка 4.20/v4l2-m2m-pr
доработка B. Roszak     : gitlab.com/benjamin545/linux-amlogic  ветка aml-hevc
FFmpeg RPi              : github.com/jc-kynesim/rpi-ffmpeg
```

---

## План работ по M13

```text
1. Применить на целевое ядро      git am 0001 0002
                                  конфликты ожидаемы: база ~v6.2, прошло 3 года
2. Починить утечку new_frame      codec_hevc.c, функция codec_hevc_prepare_new_frame()
                                  замечание Dan Carpenter, воспроизводится smatch
3. Прогнать статический анализ    make W=1 + smatch/sparse на нашей конфигурации
4. Firmware                       gxl_hevc.bin из linux-firmware в /lib/firmware/meson/vdec/
5. Тест 1080p HEVC 8-bit          сначала это, не 4K
6. Тест 4K HEVC 8-bit             целевой сценарий
7. Тест 10-bit                    патч 0001 для этого и написан; результат фиксировать честно
8. Мост в Android через Codec2    мост из M9, общий для всех кодеков
```

⚠️ Пункт 2 не пропускать. Утечка на каждый кадр при 24 fps — это гарантированное
исчерпание памяти на устройстве с 2 ГиБ ОЗУ за время фильма.

---

## Как проверить, что декод действительно аппаратный

Требование ТЗ §11: software decoding не выдаётся за аппаратное.

```bash
# формат должен появиться в списке V4L2
v4l2-ctl -d /dev/video0 --list-formats-out | grep -i hevc

# при воспроизведении 4K загрузка CPU должна оставаться низкой
top -b -n1 | head -20

# в Android — аппаратный компонент, а не c2.android.*
dumpsys media.codec | grep -i hevc
```

Если в `dumpsys` виден только `c2.android.hevc.decoder` — это программный
декодер Google, и M13 не закрыт.

---

## Обновление патчей

Серия скачана 2026-08-15. Перед началом работ проверить, не появилось ли
более свежей ревизии или merge в апстрим:

```bash
curl -s "https://patchwork.linuxtv.org/api/1.2/patches/?q=HEVC+decode+codec&order=-date" \
  | python -m json.tool | grep -E '"name"|"date"|"state"'
```

Полная серия в формате mbox также доступна как
`https://patchwork.linuxtv.org/series/10073/mbox/`.
