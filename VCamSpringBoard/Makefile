export ARCHS                 = arm64 arm64e
export TARGET                = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WBFCVCamSpring

WBFCVCamSpring_FILES = VCamSpringBoard.x \
                       ../Shared/VCamSharedState.c \
                       ../Shared/VCamConfig.m \
                       ../Shared/VCamHUDBridge.m

WBFCVCamSpring_FRAMEWORKS = UIKit Foundation CoreGraphics

WBFCVCamSpring_CFLAGS  = -fobjc-arc \
                         -I$(THEOS_PROJECT_DIR)/../Shared \
                         -Wno-deprecated-declarations

WBFCVCamSpring_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
