export ARCHS          = arm64 arm64e
export TARGET         = iphone:clang:18.5:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WBFCVCamClient

WBFCVCamClient_FILES      = VCamClient.x \
                             ../Shared/VCamSharedState.c \
                             ../Shared/VCamConfig.m

WBFCVCamClient_FRAMEWORKS = Foundation AVFoundation
WBFCVCamClient_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/../Shared
WBFCVCamClient_LDFLAGS    = -undefined dynamic_lookup
WBFCVCamClient_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
