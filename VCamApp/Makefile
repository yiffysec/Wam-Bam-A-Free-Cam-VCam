export ARCHS                 = arm64 arm64e
export TARGET                = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WamBamVCam

WamBamVCam_FILES = main.m \
                   AppDelegate.m \
                   VCamMainViewController.m \
                   VCamPerAppViewController.m \
                   ../Shared/VCamSharedState.c \
                   ../Shared/VCamConfig.m \
                   ../Shared/VCamHUDBridge.m \
                   ../Shared/VCamBootGuard.m

WamBamVCam_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo \
                        PhotosUI Photos UniformTypeIdentifiers CoreGraphics

WamBamVCam_CFLAGS  = -fobjc-arc \
                     -I$(THEOS_PROJECT_DIR)/../Shared \
                     -Wno-deprecated-declarations

WamBamVCam_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/application.mk
