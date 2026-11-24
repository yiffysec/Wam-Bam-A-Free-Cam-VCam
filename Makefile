#  Wam Bam A Free Cam -- a virtual camera for iOS 15 through 26+
#
#  Build schemes:
#     make package                                   # roothide (default)
#     make package THEOS_PACKAGE_SCHEME=rootless     # Dopamine / Xina / palera1n rootless
#     make package THEOS_PACKAGE_SCHEME=             # rootful (unc0ver / checkra1n / palera1n rootful)
#
#  Components:
#     WBFCVCamHost     -> cameracaptured (iOS 18+) / mediaserverd (iOS <=17)
#     WBFCVCamClient   -> every app, publishes the per-app verdict
#     WBFCVCamSpring   -> SpringBoard HUD (entirely optional)
#     WamBamVCam.app   -> companion app, the authoritative control surface
#     WamBamVCamPrefs  -> Settings pane via PreferenceLoader

export ARCHS                 = arm64 arm64e
export TARGET                = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WBFCVCamHost

WBFCVCamHost_FILES = VCamHost/VCamHostMain.x \
                     VCamHost/VCamHooks.x \
                     VCamHost/VCamFrameEngine.m \
                     VCamHost/VCamFrameVariant.m \
                     VCamHost/VCamPixelConverter.m \
                     VCamHost/VCamMediaSource.m \
                     Shared/VCamSharedState.c \
                     Shared/VCamDiagnostics.c \
                     Shared/VCamBootGuard.m

WBFCVCamHost_FRAMEWORKS = AVFoundation CoreMedia CoreVideo CoreImage \
                          Metal VideoToolbox Foundation CoreGraphics

WBFCVCamHost_CFLAGS  = -fobjc-arc \
                       -I$(THEOS_PROJECT_DIR)/Shared \
                       -I$(THEOS_PROJECT_DIR)/VCamHost \
                       -Wno-deprecated-declarations

# libSandy is deliberately NOT linked. It is resolved with dlopen/dlsym at
# runtime instead, so a missing or broken libSandy cannot stop this dylib from
# loading into the camera daemon -- a load failure there is a bricked camera.
WBFCVCamHost_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += VCamClient
SUBPROJECTS += VCamSpringBoard
SUBPROJECTS += VCamPrefs
SUBPROJECTS += VCamApp

include $(THEOS_MAKE_PATH)/aggregate.mk

# The companion app needs real entitlements to reach outside its sandbox.
internal-stage::
	$(ECHO_NOTHING) \
	APP="$(THEOS_STAGING_DIR)/Applications/WamBamVCam.app/WamBamVCam"; \
	if [ -f "$$APP" ]; then \
	    ldid -S$(THEOS_PROJECT_DIR)/VCamApp/entitlements.plist "$$APP" \
	        && echo "signed WamBamVCam with entitlements"; \
	fi $(ECHO_END)
