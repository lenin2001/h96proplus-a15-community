# h96proplus.mk — цель сборки
#
# Собираем userdebug: он даёт adb root, отладку и логирование, без которых
# bring-up невозможен (ТЗ §36). Переход на user — осознанное решение в конце,
# а не умолчание.

$(call inherit-product, device/h96proplus/device.mk)

PRODUCT_NAME := h96proplus
PRODUCT_DEVICE := h96proplus
PRODUCT_BRAND := Amlogic
PRODUCT_MODEL := H96 Pro Plus
PRODUCT_MANUFACTURER := Amlogic

# ⚠️ Стоковая прошивка притворялась NVIDIA Shield (ro.product.model=SHIELD
# Android TV) ради качества в Netflix. Мы этого НЕ делаем: выдавать себя за
# чужое устройство — путь к неработающим обновлениям и нарушению условий
# сервисов. Если понадобится, решение принимает владелец осознанно.
