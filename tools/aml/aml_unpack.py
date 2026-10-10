#!/usr/bin/env python3
"""
aml_unpack.py — разбор образа Amlogic USB Burning Tool (aml_upgrade_package).

Зачем свой разборщик, если есть aml_image_v2_unpacker: тот идёт в комплекте с
проприетарным Burning Tool, только под Windows и без исходников. Здесь формат
реализован по открытому описанию — работает где угодно, и видно, что именно
он делает.

Формат (Amlogic image v2), little-endian:

    Заголовок, 64 байта:
        uint32  crc                контрольная сумма всего файла после этого поля
        int32   version            2
        uint8   magic[4]           27 B5 19 56
        int64   imageSz            полный размер образа
        uint32  itemAlignSize
        uint32  itemNum            сколько элементов внутри
        uint8   reserve[36]

    Далее itemNum записей по 128 байт:
        uint32  itemId
        uint32  fileType           0 = обычный файл, 1 = разреженный
        int64   curOffsetInItem
        int64   offsetInImage      где лежат данные
        int64   itemSz             сколько байт
        char    itemMainType[32]   например "PARTITION", "USB", "conf"
        char    itemSubType[32]    например "boot", "system", "_aml_dtb"
        uint32  verify
        uint16  isBackUpItem
        uint16  backUpItemId
        uint8   reserve[24]

Использование:
    python aml_unpack.py образ.img              список содержимого
    python aml_unpack.py образ.img -o каталог   распаковать всё
    python aml_unpack.py образ.img -o кат -f _aml_dtb   только нужное
"""

import argparse
import binascii
import struct
import sys
from pathlib import Path

# Сигнатура хранится как uint32 little-endian, то есть в файле байты идут
# 56 19 B5 27. Сравнивать напрямую с bytes([0x27,0xB5,...]) — классическая
# ошибка, на которой парсер и споткнулся при первом запуске.
MAGIC = 0x27B51956
HEADER_FMT = "<IiIqII36s"
HEADER_SIZE = struct.calcsize(HEADER_FMT)
# ⚠️ Поля типов — по 256 байт, а не по 32, как пишут в большинстве описаний
# формата. Запись целиком 576 байт. Установлено по сырым байтам реального
# образа: элемент 0 начинается на 0x40, его mainType ("USB") лежит на 0x60,
# subType ("DDR") — на 0x160, а следующая запись начинается на 0x280.
# С 32-байтными полями парсер читает первую запись верно, а дальше
# рассыпается — что и случилось при первом запуске.
ITEM_FMT = "<IIqqq256s256sIHH24s"
ITEM_SIZE = struct.calcsize(ITEM_FMT)


def cstr(raw: bytes) -> str:
    """Строка фиксированной длины с нулевым завершителем."""
    return raw.split(b"\0", 1)[0].decode("utf-8", errors="replace")


def human(n: int) -> str:
    for unit in ("Б", "КиБ", "МиБ", "ГиБ"):
        if abs(n) < 1024:
            return f"{n:.0f} {unit}" if unit == "Б" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} ТиБ"


def read_header(fh):
    fh.seek(0)
    raw = fh.read(HEADER_SIZE)
    if len(raw) < HEADER_SIZE:
        raise ValueError("файл короче заголовка — это не образ Amlogic")

    crc, version, magic, image_sz, align, item_num, _ = struct.unpack(HEADER_FMT, raw)

    if magic != MAGIC:
        raise ValueError(
            f"неверная сигнатура: 0x{magic:08x} вместо 0x{MAGIC:08x} — "
            "это не образ Amlogic v2"
        )
    if version != 2:
        print(f"[!] версия формата {version}, ожидалась 2 — разбор может быть неточным",
              file=sys.stderr)

    return {
        "crc": crc,
        "version": version,
        "image_size": image_sz,
        "align": align,
        "item_num": item_num,
    }


def read_items(fh, item_num):
    fh.seek(HEADER_SIZE)
    items = []
    for i in range(item_num):
        raw = fh.read(ITEM_SIZE)
        if len(raw) < ITEM_SIZE:
            raise ValueError(f"обрыв на элементе {i}: файл повреждён или обрезан")
        (item_id, file_type, cur_off, off_in_image, item_sz,
         main_type, sub_type, verify, is_backup, backup_id, _) = struct.unpack(ITEM_FMT, raw)
        items.append({
            "id": item_id,
            "file_type": file_type,
            "offset": off_in_image,
            "size": item_sz,
            "main": cstr(main_type),
            "sub": cstr(sub_type),
            "verify": verify,
            "backup": bool(is_backup),
        })
    return items


def verify_crc(path: Path, stored_crc: int) -> bool:
    """CRC32 по всему файлу, начиная с 5-го байта.

    ⚠️ Amlogic хранит CRC32 БЕЗ ФИНАЛЬНОЙ ИНВЕРСИИ. Обычный CRC32 (zlib,
    binascii) заканчивается операцией `^ 0xFFFFFFFF`; здесь её нет, поэтому
    результат надо инвертировать обратно.

    Первая версия этой функции инверсии не делала — и объявила заведомо
    целый стоковый образ Франкенштейна 3.1 «повреждённым». Проверено
    перебором вариантов на реальном файле: совпадают ровно два,
    `~zlib.crc32(data)` и сырой табличный проход без финального XOR, —
    что одно и то же.
    """
    crc = 0
    with path.open("rb") as fh:
        fh.seek(4)
        while chunk := fh.read(8 * 1024 * 1024):
            crc = binascii.crc32(chunk, crc)
    return (~crc & 0xFFFFFFFF) == stored_crc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="куда распаковать")
    ap.add_argument("-f", "--filter", action="append",
                    help="извлекать только элементы с этим subtype (можно повторять)")
    ap.add_argument("--check-crc", action="store_true",
                    help="проверить CRC32 всего образа (читает файл целиком)")
    args = ap.parse_args()

    if not args.image.exists():
        print(f"[x] нет файла: {args.image}", file=sys.stderr)
        return 1

    with args.image.open("rb") as fh:
        try:
            hdr = read_header(fh)
        except ValueError as e:
            print(f"[x] {e}", file=sys.stderr)
            return 1

        items = read_items(fh, hdr["item_num"])

        actual = args.image.stat().st_size
        print(f"Образ    : {args.image.name}")
        print(f"Размер   : {human(actual)} ({actual} Б)")
        if hdr["image_size"] != actual:
            print(f"[!] в заголовке заявлено {human(hdr['image_size'])} — "
                  "файл обрезан или дополнен")
        print(f"Версия   : {hdr['version']}")
        print(f"CRC      : 0x{hdr['crc']:08x}")
        print(f"Элементов: {hdr['item_num']}")
        print()

        print(f"{'#':>3}  {'main':<12} {'sub':<20} {'размер':>12}  {'смещение':>12}  тип")
        print("-" * 78)
        for i, it in enumerate(items):
            ft = "sparse" if it["file_type"] == 1 else "normal"
            flag = " [backup]" if it["backup"] else ""
            print(f"{i:>3}  {it['main']:<12} {it['sub']:<20} "
                  f"{human(it['size']):>12}  {it['offset']:>12}  {ft}{flag}")

        if args.check_crc:
            print()
            print("Проверка CRC32 (читаю файл целиком)...")
            ok = verify_crc(args.image, hdr["crc"])
            print("  ✅ CRC совпал" if ok else "  ⛔ CRC НЕ СОВПАЛ — образ повреждён")

        if not args.output:
            print()
            print("Для распаковки: -o <каталог>")
            return 0

        args.output.mkdir(parents=True, exist_ok=True)
        print()
        print(f"Распаковка в {args.output}")

        extracted = 0
        for it in items:
            if args.filter and it["sub"] not in args.filter:
                continue

            # Имя вида "PARTITION_boot" — иначе элементы с одинаковым sub,
            # но разным main перезапишут друг друга.
            name = f"{it['main']}_{it['sub']}" if it["main"] else it["sub"]
            dest = args.output / name

            fh.seek(it["offset"])
            remaining = it["size"]
            with dest.open("wb") as out:
                while remaining > 0:
                    chunk = fh.read(min(8 * 1024 * 1024, remaining))
                    if not chunk:
                        print(f"  [!] {name}: обрыв, не хватило {remaining} Б")
                        break
                    out.write(chunk)
                    remaining -= len(chunk)

            print(f"  {name:<32} {human(it['size']):>12}")
            extracted += 1

        print()
        print(f"Извлечено элементов: {extracted}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
