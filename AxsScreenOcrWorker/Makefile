include ../AxsScreenOcrBuild.mk
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AxsScreenOcrWorker
AxsScreenOcrWorker_FILES = main.m AxsScreenOcrWorkerDelegate.m ../Shared/AxsScreenOcrVision.m ../Shared/AxsScreenOcrIPC.m
AxsScreenOcrWorker_CFLAGS = -fobjc-arc -I../Shared -I../Sources
AxsScreenOcrWorker_FRAMEWORKS = UIKit Foundation Vision CoreGraphics CoreImage ImageIO
AxsScreenOcrWorker_RESOURCE_DIRS = Resources
AxsScreenOcrWorker_INSTALL_PATH = /Applications
AxsScreenOcrWorker_CODESIGN_FLAGS = -S$(CURDIR)/AxsScreenOcrWorker.entitlements

include $(THEOS_MAKE_PATH)/application.mk
