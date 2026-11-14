include ../AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = AxsScreenOcrHelper
AxsScreenOcrHelper_FILES = AxsScreenOcrHelperMain.mm
AxsScreenOcrHelper_CFLAGS = -fobjc-arc
AxsScreenOcrHelper_FRAMEWORKS = Foundation Vision ImageIO CoreGraphics
AxsScreenOcrHelper_INSTALL_PATH = /usr/libexec

# 裸二进制默认没有任何权限，Vision 内部申请 IOSurface 后端的像素缓冲会被拒。
# 带上 platform-application 等权限后，helper 才被当作平台进程对待。
AxsScreenOcrHelper_CODESIGN_FLAGS = -S$(CURDIR)/AxsScreenOcrHelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
