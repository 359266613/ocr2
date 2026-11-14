include ../AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsScreenOcrPrefs
AxsScreenOcrPrefs_FILES = $(wildcard *.m) ../Shared/AxsScreenOcrVision.m ../Sources/AxsScreenOcrRecognizer.m ../Sources/AxsScreenOcrLog.m
AxsScreenOcrPrefs_CFLAGS = -fobjc-arc -I../Sources -I../Shared
AxsScreenOcrPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation Vision CoreGraphics ImageIO CoreImage
AxsScreenOcrPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsScreenOcrPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
