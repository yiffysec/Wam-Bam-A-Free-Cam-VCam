# ARCHS and TARGET are conditional so the root Makefile's exported
# values win when built as a subproject, and a standalone build of
# this component still has sane defaults. An earlier hardcoded SDK
# version here drifted out of step with the root and broke the build
# with "Your chosen SDK does not appear to exist".
export ARCHS                ?= arm64 arm64e
export TARGET               ?= iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WamBamVCamPrefs

WamBamVCamPrefs_FILES = VCamRootListController.m \
                        ../Shared/VCamSharedState.c \
                        ../Shared/VCamDiagnostics.c \
                        ../Shared/VCamConfig.m \
                        ../Shared/VCamHUDBridge.m \
                        ../Shared/VCamBootGuard.m

WamBamVCamPrefs_FRAMEWORKS = UIKit Foundation

# Preferences is deliberately NOT linked. Theos ships its headers in
# vendor/include, so PSListController compiles, but the SDK's
# Preferences.framework carries only a .tbd with no linkable stub, and
# -framework Preferences fails with "framework 'Preferences' not found".
#
# Linking it is unnecessary anyway: this bundle is loaded into Settings, where
# Preferences.framework is already resident, so -undefined dynamic_lookup below
# resolves the PSListController class reference at load time. That is also one
# fewer SDK-shaped thing that can break on a future SDK.

WamBamVCamPrefs_CFLAGS  = -fobjc-arc \
                          -I$(THEOS_PROJECT_DIR)/../Shared \
                          -Wno-deprecated-declarations

WamBamVCamPrefs_LDFLAGS      = -undefined dynamic_lookup
WamBamVCamPrefs_INSTALL_PATH = /Library/PreferenceLoader/Preferences/WamBamVCam

include $(THEOS_MAKE_PATH)/bundle.mk
