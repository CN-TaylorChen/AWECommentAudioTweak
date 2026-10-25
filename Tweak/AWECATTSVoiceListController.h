// 豆包 TTS 音色
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import <UIKit/UIKit.h>
#import "AWECATTSManager.h"

@interface AWECATTSVoiceListController : UITableViewController <UISearchBarDelegate>

@property (nonatomic, copy) void(^onVoiceSelected)(NSString *voiceType, NSString *voiceName);
// YES=FishAudio 音色库（reference_id + 自定义头像），NO=火山音色列表
@property (nonatomic, assign) BOOL fishMode;
// 情绪标签管理模式：点行勾选/取消，左滑编辑/删除，右上角＋新增
@property (nonatomic, assign) BOOL emotionMode;
@property (nonatomic, copy) void(^onEmotionsChanged)(void);

@end
