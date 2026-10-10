#!/system/bin/sh
# h96-standby.sh (25.09.2026): allow deep suspend only if the kernel supports remote wake.
# meson_gx_pm hands the IR power key to BL301 before every suspend and refuses suspend if it
# cannot; without that parameter (older kernel) the h96-no-suspend wake lock must stay.
K=/sys/module/meson_gx_pm/parameters/ir_wake_key
if [ -r "$K" ] && [ "$(cat "$K")" != "0" ]; then
    echo h96-no-suspend > /sys/power/wake_unlock
    log -t h96-standby "remote standby enabled (ir_wake_key=$(cat "$K")), wake lock released"
else
    log -t h96-standby "kernel without remote wake: keeping h96-no-suspend"
fi
