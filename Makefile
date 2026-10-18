# iPhone X (A11, arm64) on iOS 16.x. Rootless is the default scheme.
# For a rootful jailbreak, delete the THEOS_PACKAGE_SCHEME line.
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ClockFont
ClockFont_FILES = Tweak.x
ClockFont_CFLAGS = -fobjc-arc
ClockFont_FRAMEWORKS = UIKit CoreText

include $(THEOS_MAKE_PATH)/tweak.mk
