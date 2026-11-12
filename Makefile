TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# 无根越狱（Dopamine / palera1n rootless）打开这一行；有根越狱保持注释
# THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenOCR

ScreenOCR_FILES = Tweak.xm \
                  OCRCapture.m \
                  OCREngine.m \
                  OCRGesture.m \
                  OCRResultViewController.m

ScreenOCR_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ScreenOCR_FRAMEWORKS = UIKit Foundation Vision ImageIO QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
