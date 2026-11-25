# ARCHS and TARGET are conditional so the root Makefile's exported
# values win when built as a subproject, and a standalone build of
# this component still has sane defaults. An earlier hardcoded SDK
# version here drifted out of step with the root and broke the build
# with "Your chosen SDK does not appear to exist".
export ARCHS                ?= arm64 arm64e
export TARGET               ?= iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WBFCVCamClient

WBFCVCamClient_FILES      = VCamClient.x \
                             ../Shared/VCamSharedState.c \
                             ../Shared/VCamPaths.m \
                             ../Shared/VCamDiagnostics.c \
                             ../Shared/VCamConfig.m \
                             ../Shared/VCamFloatingHUD.m

WBFCVCamClient_FRAMEWORKS = Foundation AVFoundation UIKit CoreGraphics
WBFCVCamClient_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/../Shared
WBFCVCamClient_LDFLAGS    = -undefined dynamic_lookup
WBFCVCamClient_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
