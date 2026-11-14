DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

# Share the SDK and deployment targets with the PreferenceBundle and the helper.
include AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsScreenOcr
AxsScreenOcr_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsScreenOcr_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsScreenOcr_FRAMEWORKS = UIKit Foundation CoreFoundation Vision ImageIO
AxsScreenOcr_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Vision 识别放在独立进程，避免在 SpringBoard 里加载模型导致 safemode。
SUBPROJECTS += AxsScreenOcrPrefs AxsScreenOcrHelper
include $(THEOS_MAKE_PATH)/aggregate.mk
