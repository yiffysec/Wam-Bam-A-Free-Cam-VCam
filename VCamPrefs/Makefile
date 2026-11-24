export ARCHS                 = arm64 arm64e
export TARGET                = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WamBamVCamPrefs

WamBamVCamPrefs_FILES = VCamRootListController.m \
                        ../Shared/VCamSharedState.c \
                        ../Shared/VCamDiagnostics.c \
                        ../Shared/VCamConfig.m \
                        ../Shared/VCamHUDBridge.m \
                        ../Shared/VCamBootGuard.m

WamBamVCamPrefs_FRAMEWORKS         = UIKit Foundation
WamBamVCamPrefs_PRIVATE_FRAMEWORKS = Preferences

WamBamVCamPrefs_CFLAGS  = -fobjc-arc \
                          -I$(THEOS_PROJECT_DIR)/../Shared \
                          -Wno-deprecated-declarations

WamBamVCamPrefs_LDFLAGS      = -undefined dynamic_lookup
WamBamVCamPrefs_INSTALL_PATH = /Library/PreferenceLoader/Preferences/WamBamVCam

include $(THEOS_MAKE_PATH)/bundle.mk
