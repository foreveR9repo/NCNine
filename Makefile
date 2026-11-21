export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NCNine
NCNine_FILES = Tweak.x NCI9Store.m NCI9ViewController.m
NCNine_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
NCNine_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
