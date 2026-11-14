include ../AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsScreenOcrPrefs
AxsScreenOcrPrefs_FILES = $(wildcard *.m)
AxsScreenOcrPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsScreenOcrPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsScreenOcrPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsScreenOcrPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
