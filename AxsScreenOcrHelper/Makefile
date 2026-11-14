include ../AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = AxsScreenOcrHelper
AxsScreenOcrHelper_FILES = AxsScreenOcrHelperMain.mm ../Shared/AxsScreenOcrVision.m
AxsScreenOcrHelper_CFLAGS = -fobjc-arc -I../Shared -I../Sources
AxsScreenOcrHelper_FRAMEWORKS = Foundation Vision ImageIO CoreGraphics CoreImage
AxsScreenOcrHelper_INSTALL_PATH = /usr/libexec

# These requested entitlements do not prove the device grants model access.
AxsScreenOcrHelper_CODESIGN_FLAGS = -S$(CURDIR)/AxsScreenOcrHelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
