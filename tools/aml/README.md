# Amlogic image tools

Инструменты для распаковки/сборки `aml_upgrade_package.img`.

**В репозиторий не коммитятся** (см. `.gitignore`) — распространяются отдельно,
лицензионный статус неясен.

## Что положить сюда

```text
aml_image_v2_unpacker    распаковать стоковый образ
aml_image_v2_packer      собрать свой образ
```

Оба входят в состав Amlogic USB Burning Tool либо собираются из открытых
реализаций сообщества.

## Использование

```bash
# распаковать сток (делается на Milestone 2)
./aml_image_v2_unpacker stock/aml_upgrade_package.img unpacked/

# собрать свой (Milestone 12)
./aml_image_v2_packer -r image.cfg output/ firmware.img
```

⚠️ Offsets и размеры разделов брать **только** из распакованного стока или с
живого устройства.
