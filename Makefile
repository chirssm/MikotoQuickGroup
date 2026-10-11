TARGET := iphone:clang:latest:14.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = WeChat

# 越狱环境安装路径方案：
#   rootless  → /var/jb/Library/MobileSubstrate/DynamicLibraries/   (Dopamine / palera1n rootless)
#   roothide  → /var/jb/... (roothide bootstrap)
#   (留空)    → /Library/MobileSubstrate/DynamicLibraries/          (checkra1n / unc0ver 有根越狱)
# 如果你只是要拿到 .dylib 手动注入，这一项不影响产物本身。
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MikotoQuickGroup
MikotoQuickGroup_FILES = Tweak.xm
MikotoQuickGroup_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
MikotoQuickGroup_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
