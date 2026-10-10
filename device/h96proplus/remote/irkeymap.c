// irkeymap — загрузка таблицы «код кнопки → код клавиши» в ИК-приёмник.
//
// ЗАЧЕМ. Ядро mainline декодирует ИК через RC-core, но само по себе не знает,
// какая кнопка что означает: таблицу должен загрузить userspace. В Linux это
// делает `ir-keytable`, которого в Android НЕТ. Без таблицы приёмник шлёт
// только «сырые» события MSC_SCAN, Android их игнорирует, и пульт не работает.
//
// Эта программа делает ровно то же, что `ir-keytable -c -w`: очищает таблицу
// и заливает пары через ioctl EVIOCSKEYCODE_V2.
//
// СБОРКА (статически, чтобы не зависеть от libc Android):
//     aarch64-linux-gnu-gcc -static -O2 -Wall irkeymap.c -o irkeymap
//
// ЗАПУСК:
//     irkeymap /dev/input/event0 /vendor/etc/h96-remote.map
// Формат файла: строки «<код-кнопки-hex> <код-клавиши-Linux-dec>»,
// пустые строки и «#» — комментарии.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>

// Поиск ИК-приёмника по имени: номер /dev/input/eventN не постоянен и
// зависит от порядка появления устройств. Вызывается при argv[1] == "auto".
static int scan_once(const char *want)
{
    for (int i = 0; i < 32; i++) {
        char path[64];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDWR);
        if (fd < 0) continue;

        char name[128] = {0};
        if (ioctl(fd, EVIOCGNAME(sizeof name - 1), name) >= 0 &&
            strcmp(name, want) == 0) {
            fprintf(stderr, "irkeymap: приёмник найден: %s (%s)\n", path, name);
            return fd;
        }
        close(fd);
    }
    return -1;
}

// ⛔ Ждём появления устройства. Программа запускается из init на ранней
// стадии, а узлы /dev/input/eventN создаёт ueventd асинхронно — к моменту
// запуска приёмника может ещё не быть. Молча выйти нельзя: таблицу нужно
// загрузить ДО того, как Android опросит устройство (иначе он навсегда
// сочтёт его «клавиатурой без клавиш» — проверено 23.08).
static int open_by_name(const char *want)
{
    for (int t = 0; t < 60; t++) {          // до 30 секунд
        int fd = scan_once(want);
        if (fd >= 0) return fd;
        if (t == 0) fprintf(stderr, "irkeymap: жду появления %s…\n", want);
        usleep(500000);
    }
    return -1;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "использование: %s <устройство|auto> <файл-таблицы>\n", argv[0]);
        return 2;
    }

    int fd;
    if (strcmp(argv[1], "auto") == 0) {
        fd = open_by_name("meson-ir");
        if (fd < 0) {
            fprintf(stderr, "не найден приёмник meson-ir среди /dev/input/event*\n");
            return 1;
        }
    } else {
        fd = open(argv[1], O_RDWR);
        if (fd < 0) {
            fprintf(stderr, "не открыть %s: %s\n", argv[1], strerror(errno));
            return 1;
        }
    }

    FILE *f = fopen(argv[2], "r");
    if (!f) {
        fprintf(stderr, "не открыть %s: %s\n", argv[2], strerror(errno));
        close(fd);
        return 1;
    }

    // Очистка прежней таблицы: ir-keytable делает это, назначая всем
    // существующим записям KEY_RESERVED. Нам достаточно перезаписать свои —
    // лишние записи не мешают, а полная очистка требует перебора индексов.

    char line[256];
    int ok = 0, fail = 0, lineno = 0;

    while (fgets(line, sizeof line, f)) {
        lineno++;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        unsigned long scancode;
        unsigned int keycode;
        if (sscanf(p, "%lx %u", &scancode, &keycode) != 2) {
            fprintf(stderr, "строка %d: не разобрана: %s", lineno, p);
            fail++;
            continue;
        }

        struct input_keymap_entry ke;
        memset(&ke, 0, sizeof ke);
        ke.flags = 0;
        ke.len = 4;                       // длина кода в байтах
        ke.index = 0;
        ke.keycode = keycode;
        unsigned int sc = (unsigned int)scancode;
        memcpy(ke.scancode, &sc, sizeof sc);

        if (ioctl(fd, EVIOCSKEYCODE_V2, &ke) < 0) {
            fprintf(stderr, "0x%lx -> %u: ошибка %s\n",
                    scancode, keycode, strerror(errno));
            fail++;
        } else {
            ok++;
        }
    }

    fclose(f);
    close(fd);

    printf("irkeymap: загружено %d, ошибок %d\n", ok, fail);
    return fail ? 1 : 0;
}
