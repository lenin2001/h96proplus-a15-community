# Firmware декодера (meson-vdec)

Микрокод видеодекодера Amlogic. **Сами `.bin` в git не коммитятся** —
это бинарные блобы, исключены в `.gitignore`. Здесь только их описание,
контрольные суммы и способ получить.

## Где лежат копии

```text
источник      : linux-firmware.git, каталог meson/vdec/, тег 20260916
                (коммит ab23307cfe7f9366c819025ca3e4778299bc2db2)
загрузка      : build/fetch-firmware.sh — сверяет SHA-256 каждого файла
на устройстве : /vendor/firmware/meson/vdec/ (firmware_class.path=/vendor/firmware)
```

Лицензия — из `WHENCE` в linux-firmware:

```text
Driver: meson-vdec - Amlogic video decoder
Licence: Redistributable. See LICENSE.amlogic_vdec for details.
```

То есть распространять можно, включая в образ прошивки.

## Состав и контрольные суммы

| Файл | Размер | SHA256 | Зачем нам |
|---|---|---|---|
| `gxl_hevc.bin` | 16 384 | `f13362950539e9e1594625908540dee54c143432b7900ee198d5ef17a62c58d1` | **HEVC для GXM** — именно его требует патч M13 |
| `gxl_hevc_mmu.bin` | 16 384 | `1b8b511e50c4c92efb76a999722c3826c54c0170fd04d9bc4c533991ebe4f481` | вариант с MMU (для G12A+, у нас вряд ли) |
| `gxm_h264.bin` | 36 864 | `3a89d735ca87d5075e27c1bbe1fa6534e875a14fda7776831ff3c16b1a5b8104` | H.264 на нашем SoC |
| `gxl_h264.bin` | 36 864 | `fbefe7ec333a05c6dad03b21145b0b2766bbc033c8d1855f91aeea123f485bec` | H.264, вариант GXL |
| `gxl_vp9.bin` | 16 384 | `cf40af8d5e8b02a247c28f99cd8afe8094e4c4078817e37c4c98f57c57e87998` | **VP9** — то, что даёт 4K уже сейчас |
| `gxl_mpeg12.bin` | 16 384 | `4a851302785a48e84cb846e5e974a4f51a4ca87c52d961aab4307b1c91daf2b2` | MPEG-1/2 |

Сохранённые суммы — не формальность: если декодер поведёт себя странно,
первое, что надо исключить, — что подсунут другой или битый микрокод.

## Как получить

```bash
build/fetch-firmware.sh     # из корня репозитория
```

Скрипт берёт файлы с закреплённого тега linux-firmware `20260916`, сверяет
SHA-256 каждого (микрокод — по `device/h96proplus/firmware/SHA256SUMS`,
Wi-Fi — по `ath10k/QCA9377/hw1.0/MANIFEST.txt`) и при любом расхождении
останавливается, ничего не положив. Вместе с файлами скачиваются тексты
лицензий `LICENSE.amlogic_vdec` и `LICENSE.QualcommAtheros_ath10k`.
Брать файлы с `master` без закреплённой ревизии нельзя: содержимое может
смениться, а таблица выше перестанет описывать то, что попало в образ.

## Как файлы попадают на устройство

`device/h96proplus/device.mk` копирует микрокод в образ vendor
(`/vendor/firmware/meson/vdec/`), а Wi-Fi — в `/vendor/firmware/ath10k/...`.
Ядро ищет их там по параметру `firmware_class.path=/vendor/firmware`.

## Проверка, что микрокод подхватился

```bash
adb shell dmesg | grep -iE 'vdec|firmware'
```

Типичная ошибка при отсутствии файла:

```text
meson-vdec: Failed to request firmware meson/vdec/gxl_hevc.bin
```

Она же — первое, что надо проверить, если HEVC не появился в
`v4l2-ctl --list-formats-out`.
