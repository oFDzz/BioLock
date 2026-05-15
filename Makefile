THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BioLock

BioLock_FILES = Tweak.x
BioLock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BioLock_FRAMEWORKS = UIKit LocalAuthentication
BioLock_PRIVATE_FRAMEWORKS = SpringBoardServices FrontBoardServices

BUNDLE_NAME = BioLockPrefs

BioLockPrefs_FILES = BioLockPrefs/BLRootListController.m
BioLockPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BioLockPrefs_FRAMEWORKS = UIKit Foundation
BioLockPrefs_PRIVATE_FRAMEWORKS = Preferences
BioLockPrefs_INSTALL_PATH = /Library/PreferenceBundles
BioLockPrefs_RESOURCE_DIRS = BioLockPrefs/Resources
BioLockPrefs_CODESIGN_FLAGS = -SBioLockPrefs.entitlements

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
