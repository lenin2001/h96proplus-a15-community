# AndroidProducts.mk — точка входа для lunch

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/h96proplus.mk

COMMON_LUNCH_CHOICES := \
    h96proplus-userdebug \
    h96proplus-eng
