#!/system/bin/sh
# Сторож загрузки. После boot_completed сетью управляет Android.
#
# ═══ ГЛАВНОЕ ИСПРАВЛЕНИЕ 25.08.2026 ═══
#
# Раньше в конце стояла команда `reboot`. Она НЕ РАБОТАЕТ ровно в том
# случае, ради которого сторож и написан: `reboot` лишь выставляет свойство
# sys.powerctl, а исполняет его INIT. Когда init заблокирован — а он
# блокируется именно при зависании загрузки, — перезагрузка не наступает
# никогда. Сторож честно отсчитывал 25 минут и упирался в ту же стену:
# приставка висела часами, и вернуть её можно было только передёргиванием
# питания (24 и 25.08, три раза подряд).
#
# Теперь перезагрузка идёт КОМАНДОЙ ЯДРУ через /proc/sysrq-trigger, минуя
# init полностью. В ядре есть CONFIG_MAGIC_SYSRQ=y, но маску прав надо
# открыть: по умолчанию 0x1 разрешает только уровень логов, а перезагрузка
# требует 0x40. Пишем 1 (разрешить всё) заранее, а не в момент нужды.
#
# Почему это возвращает в СТОК: команда `update` в misc одноразовая, поэтому
# после любой перезагрузки загрузчик берёт сток из eMMC, где доступны adb,
# ramoops прошлой сессии и /data/bootlog.txt с карты. sysrq-перезагрузка
# тёплая, так что ramoops её переживает.
#
# ═══ ОСТАЛЬНЫЕ ЗАДАЧИ ═══
#
# Задача 1 — держать adb доступным на ВСЕХ фазах загрузки.
#   Разовый `ifconfig` в post-fs не годится: он отрабатывает на 13-й
#   секунде, а линк RTL8211F поднимается на 17-й, плюс позже адрес
#   сбрасывает netd/ConnectivityService (попытка №12 — сети не было,
#   хотя adbd слушал 5555 и Ethernet дал 1 Гбит/с).
#
# Задача 2 — вернуть зависшую систему в сток без передёргивания питания.

# Optional emergency static address for the legacy SD bring-up profile only:
# empty (the default) disables it. Set via androidboot.h96.static_ip=<IPv4>.
IP=$(getprop ro.boot.h96.static_ip)

# SD boot flags and emergency static Ethernet belong only to the old SD
# bring-up profile. An eMMC boot must never mount/write mmcblk0p1 by guess.
is_sd_boot() {
    case "$(getprop ro.boot.fstab_suffix)" in
        sdboot) return 0 ;;
        "") grep -q 'androidboot.fstab_suffix=sdboot\( \|$\)' /proc/cmdline ;;
        *) return 1 ;;
    esac
}

# ── два порога вместо одного ──────────────────────────────────────────────
# Прежний единственный порог в 25 минут был компромиссом между двумя
# несовместимыми случаями и плохо решал оба:
#   * init завис намертво — ждать 25 минут незачем, всё уже ясно;
#   * первая загрузка со свежим /data честно занимает много времени
#     (dex2oat компилирует пакеты на 8xA53 с SD-карты), и попытка №20
#     перезагрузилась моим же сторожем посреди работы PackageManager.
# Различаем их по признаку прогресса: если init дошёл до запуска adbd,
# значит он жив и просто медленно работает. Если за 6 минут adbd так и не
# поднялся — init заблокирован, ждать бессмысленно.
WEDGE_CHECKS=12      # 12 x 30 с = 6 минут без adbd  -> init заблокирован
# ⛔ 03.09: порог 25 минут превращал отладку в пытку — каждый цикл зависшей
# загрузки съедал полчаса, а данных не приносил. Но и 8 минут оказалось
# мало: ПЕРВАЯ загрузка с чистым /data (dex2oat всех пакетов на 8xA53 с
# SD-карты) честно занимает больше, и короткий порог стрелял бы по живой
# системе. 40 тиков = 20 минут: первому запуску хватает, а цикл отладки
# всё равно вдвое короче старого.
SLOW_CHECKS=40       # 40 x 30 с = 20 минут с adbd   -> загрузка не удалась

# ⛔ Страховка для memfd. Свойство лежит в /system/build.prop, но по факту
# к моменту старта system_server оказывается пустым (попытки №15-16:
# libcutils снова шёл в /dev/ashmem, которого в mainline нет). Ставим его
# принудительно здесь — сторож запускается в post-fs, задолго до
# system_server (~68 с), и в permissive-режиме bring-up установка проходит.
setprop sys.use_memfd true

# Права sysrq открываем СРАЗУ: если система к моменту нужды будет совсем
# плоха, лишняя запись в /proc может уже не пройти.
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null

# Диагностика в ФАЙЛ: /dev/kmsg переживает только 16 КБ и вытесняется
# спамом крэш-петли, а logcat не показывает kmsg. Файл читается из стока.
{
    echo "started $(date)"
    echo "use_memfd=$(getprop sys.use_memfd)"
    echo "treble=$(getprop ro.treble.enabled)"
    echo "sysrq_mask=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"
} >> /data/bootwatchdog.log 2>&1

# ── счётчик попыток ведёт СТОРОЖ, а не загрузчик ──────────────────────────
# ⛔ 03.09: fatwrite у стокового u-boot ненадёжен — пять циклов подряд он
# не оставил на FAT ни одного TRY-флага (вероятно, спотыкается о «грязный»
# том), и приставка кружила вечно вместо того, чтобы выйти в rescue. Флаги
# теперь ставит сторож перед своей перезагрузкой: TRY1 после первой
# неудачи, TRY2 после второй — третью загрузку u-boot отдаёт rescue.
# Сброс по успешной загрузке остаётся в clear_boot_counter, как и был.
escalate_try_flag() {
    is_sd_boot || return 0
    mkdir -p /mnt/sdboot 2>/dev/null
    umount /mnt/sdboot 2>/dev/null
    if mount -t vfat -o rw /dev/block/mmcblk0p1 /mnt/sdboot 2>/dev/null; then
        if [ -f /mnt/sdboot/TRY1 ]; then
            echo T > /mnt/sdboot/TRY2
            echo "BOOTWATCHDOG: попытка 2 провалена, TRY2 -> следующая загрузка уйдёт в rescue" > /dev/kmsg
        else
            echo T > /mnt/sdboot/TRY1
            echo "BOOTWATCHDOG: попытка 1 провалена, поставлен TRY1" > /dev/kmsg
        fi
        sync
        umount /mnt/sdboot 2>/dev/null
    else
        echo "BOOTWATCHDOG: не смог смонтировать p1 для TRY-флага" > /dev/kmsg
    fi
}

# ── полный снимок зависшей системы ────────────────────────────────────────
# ⛔ 03.09: четыре свойства в REBOOT-записи не отвечали на главный вопрос —
# ГДЕ стоит загрузка. Перед перезагрузкой собираем всё, что нужно для
# диагноза, в /data/wdsnap/: логи, процессы, свойства, сеть, память.
# Каталог читается из rescue по httpd, диагностика приезжает сама.
snapshot_wedge() {
    d=/data/wdsnap/$(cat /proc/uptime | cut -d. -f1)s
    mkdir -p "$d" 2>/dev/null
    getprop                         > "$d/getprop.txt"    2>&1
    ps -A -o PID,PPID,RSS,STAT,TIME,NAME > "$d/ps.txt"    2>&1
    dmesg | tail -400               > "$d/dmesg.txt"      2>&1
    timeout 20 logcat -d -t 1200    > "$d/logcat.txt"     2>&1
    timeout 10 logcat -d -b crash -t 200 > "$d/logcat-crash.txt" 2>&1
    {
        ip addr; ip route; ip rule
        echo ---; ip route show table eth0 2>/dev/null
        echo ---; cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | head -30
    }                               > "$d/net.txt"        2>&1
    df -k                           > "$d/df.txt"         2>&1
    cat /proc/meminfo               > "$d/meminfo.txt"    2>&1
    sync
}

# ── перезагрузка в обход init ─────────────────────────────────────────────
hard_reboot() {
    reason="$1"
    echo "BOOTWATCHDOG: $reason -> sysrq reboot" > /dev/kmsg
    {
        echo "REBOOT $(date): $reason"
        echo "  boot_completed=$(getprop sys.boot_completed)"
        echo "  init.svc.adbd=$(getprop init.svc.adbd)"
        echo "  init.svc.servicemanager=$(getprop init.svc.servicemanager)"
        echo "  init.svc.zygote=$(getprop init.svc.zygote)"
        echo "  init.svc.vendor.media.c2=$(getprop init.svc.android-hardware-media-c2-v4l2-hal-1-2)"
    } >> /data/bootwatchdog.log 2>&1
    snapshot_wedge
    escalate_try_flag

    sync
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null   # синхронизировать диски
    sleep 3
    echo b > /proc/sysrq-trigger 2>/dev/null   # немедленный сброс, минуя init

    # Если sysrq по какой-то причине недоступен — пробуем штатный путь.
    # Он сработает, только если init жив, но хуже не сделает.
    sleep 5
    reboot
}

# После успешной загрузки сторож завершается. Потеря Ethernet/шлюза или
# остановленный ADB не являются доказательством зависания Android. Прежний
# post_boot_watch переписывал маршруты eth0 и перезагружал работающий бокс,
# мешая Wi-Fi и обычной автономной работе.

# ── сброс счётчика попыток загрузки ───────────────────────────────────────
# Загрузчик (aml_autoscript рев. 2) перед каждой загрузкой Android ставит
# на FAT-разделе карты файл-флаг: TRY1 на первой попытке, TRY2 на второй.
# Увидев TRY2, он грузит уже не Android, а rescue.img — спасательный образ
# с сетью и telnet. Смысл в том, чтобы зависшая приставка сама выходила на
# связь, а не ждала, пока карту вынут и отнесут в ПК.
#
# Флаги обязана снимать именно система, ДОКАЗАВШАЯ работоспособность, то
# есть дошедшая до sys.boot_completed=1. Иначе двух перезагрузок подряд по
# любой причине (например, владелец выключил приставку из розетки на
# середине загрузки) хватило бы, чтобы следующий старт ушёл в спасательный
# режим вместо кино.
clear_boot_counter() {
    is_sd_boot || return 0
    mkdir -p /mnt/sdboot 2>/dev/null
    umount /mnt/sdboot 2>/dev/null
    if mount -t vfat -o rw /dev/block/mmcblk0p1 /mnt/sdboot 2>/dev/null; then
        rm -f /mnt/sdboot/TRY1 /mnt/sdboot/TRY2 2>/dev/null
        sync
        umount /mnt/sdboot 2>/dev/null
        echo "BOOTWATCHDOG: счётчик попыток загрузки сброшен" > /dev/kmsg
        echo "COUNTER-CLEARED $(date)" >> /data/bootwatchdog.log
    else
        echo "BOOTWATCHDOG: НЕ СМОГ смонтировать p1 для сброса счётчика" > /dev/kmsg
        echo "COUNTER-CLEAR-FAILED $(date)" >> /data/bootwatchdog.log
    fi
}

i=0
adbd_seen=0
while : ; do
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        echo "OK $(date): загрузка завершена за $((i * 30)) с" >> /data/bootwatchdog.log
        clear_boot_counter
        exit 0
    fi

    # Признак того, что init жив и продвигается.
    [ "$(getprop init.svc.adbd)" = "running" ] && adbd_seen=1

    # Адрес мог не назначиться (нет линка) — чиним. ⚠️ 25.08: критерий
    # сменён с «есть ли именно $IP» на «есть ли ЛЮБОЙ адрес»: старая нянька
    # навешивала статику ПОВЕРХ живого DHCP-адреса, а конфигурация мимо
    # ConnectivityService — один из подозреваемых в отзыве сети (глухоте).
    if [ -n "$IP" ] && is_sd_boot && ! ip addr show eth0 2>/dev/null | grep -q "inet "; then
        ifconfig eth0 "$IP" netmask 255.255.255.0 up 2>/dev/null
        echo "BOOTWATCHDOG: (re)applied $IP on eth0" > /dev/kmsg
    fi

    i=$((i + 1))

    if [ "$adbd_seen" = "0" ] && [ $i -ge $WEDGE_CHECKS ]; then
        hard_reboot "init заблокирован: за $((i * 30)) с не поднялся даже adbd"
    fi
    if [ $i -ge $SLOW_CHECKS ]; then
        hard_reboot "загрузка не завершилась за $((i * 30)) с"
    fi

    sleep 30
done
