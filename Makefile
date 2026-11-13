DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# rootless / roothide 至少要 iOS 15
ifneq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
TARGET = iphone:clang:16.5:15.0
else
TARGET = iphone:clang:16.5:14.0
endif

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenOCR

ScreenOCR_FILES = Tweak.xm \
                  OCRTrigger.m \
                  OCRCapture.m \
                  OCREngine.m \
                  OCRGesture.m \
                  OCRResultViewController.m

ScreenOCR_CFLAGS = -fobjc-arc -I. -Wno-deprecated-declarations
ScreenOCR_FRAMEWORKS = UIKit Foundation ImageIO QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

# Vision 识别放在独立进程里（helper），避免在 SpringBoard 里加载模型导致 safemode
SUBPROJECTS += helper
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
