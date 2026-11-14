DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

# Share the SDK and deployment targets with the Preferences bundle and app.
include AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsScreenOcr
AxsScreenOcr_FILES = $(wildcard Hooks/*.xm Sources/*.m) Shared/AxsScreenOcrIPC.m
AxsScreenOcr_CFLAGS = -fobjc-arc -I./Headers -I./Sources -I./Shared
AxsScreenOcr_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsScreenOcr_PRIVATE_FRAMEWORKS = SpringBoardServices
AxsScreenOcr_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Production Vision runs in the UIKit app, never the SpringBoard dylib.
SUBPROJECTS += AxsScreenOcrPrefs AxsScreenOcrWorker
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm
