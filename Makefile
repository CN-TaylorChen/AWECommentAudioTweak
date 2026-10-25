# 评论语音插件
# @cookieodd | github.com/cookieodd | t.me/cookieodd

ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Shenglin

Shenglin_FILES = Tweak/Tweak.x \
	Tweak/AWECADownloadManager.m \
	Tweak/AWECAAudioReplacer.m \
	Tweak/AWECAAudioPickerController.m \
	Tweak/AWECAAPISettingsController.m \
	Tweak/AWECAUtils.m \
	Tweak/AWECATTSManager.m \
	Tweak/AWECATTSController.m \
	Tweak/AWECATTSVoiceListController.m \
	Tweak/AWECACommentHeaderButton.m \
	Tweak/AWECARecordEnhance.m \
	Tweak/AWECATOSUploader.m

Shenglin_CFLAGS = -fobjc-arc
Shenglin_LDFLAGS = -Xlinker -not_for_dyld_shared_cache
Shenglin_FRAMEWORKS = UIKit Foundation AVFoundation CoreAudio CoreMedia UniformTypeIdentifiers SafariServices PhotosUI
Shenglin_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/library.mk

# 产物拷到根目录
after-all::
	$(ECHO_NOTHING)cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
