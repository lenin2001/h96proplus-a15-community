#!/system/bin/sh
# Перепривязка Bluetooth-драйвера hci_qca (03.09.2026).
#
# Зачем: драйвер встроен в ядро (=y) и пробует QCA9377 на 2-й секунде
# загрузки — задолго до монтирования /vendor. Прошивки rampatch/nvm лежат
# в /vendor/firmware/qca (firmware_class.path), поэтому первая проба
# остаётся без прошивки, и hci0 висит без инициализации. Перепривязка
# повторяет пробу, когда vendor уже смонтирован: чип штатно получает
# rampatch_00230302.bin + nvm и отвечает «QCA setup on UART is completed».
#
# Запускается из init.h96proplus.rc на post-fs (vendor смонтирован
# first-stage init-ом ещё раньше, BT HAL стартует позже — гонки нет).
D=/sys/bus/serial/drivers/hci_uart_qca
echo serial0-0 > "$D/unbind" 2>/dev/null
sleep 1
echo serial0-0 > "$D/bind" 2>/dev/null
echo "H96-BTFIX: hci_uart_qca перепривязан" > /dev/kmsg
