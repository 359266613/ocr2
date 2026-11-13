ARCHS = arm64 arm64e

ifneq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
TARGET = iphone:clang:16.5:15.0
else
TARGET = iphone:clang:16.5:14.0
endif

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ScreenOCRHelper
ScreenOCRHelper_FILES = ScreenOCRHelperMain.m
ScreenOCRHelper_CFLAGS = -fobjc-arc
ScreenOCRHelper_FRAMEWORKS = Foundation Vision ImageIO CoreGraphics CoreVideo
ScreenOCRHelper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
