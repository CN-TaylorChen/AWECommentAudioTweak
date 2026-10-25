// API 凭证分组设置页（v1.4.6 重设计）
// 旧版是 8 个输入框塞一个 UIAlertController：乱、Key 密文看不见。
// 新版：火山 / Fish / 高级（TOS + 识别资源 ID，默认折叠）三组，
// 每个 Key 右侧眼睛按钮一键明文，每组底部附获取指引。
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECAAPISettingsController.h"
#import "AWECATTSManager.h"
#import "AWECATOSUploader.h"
#import "AWECARecordEnhance.h"
#import "AWECAUtils.h"

#pragma mark - 输入行 Cell（label + 输入框 + 眼睛按钮）

@interface AWECAAPIFieldCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIButton *eyeBtn;
@property (nonatomic, copy) void (^onEyeToggle)(AWECAAPIFieldCell *cell);
@end

@implementation AWECAAPIFieldCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:14];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [_titleLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self.contentView addSubview:_titleLabel];

        _field = [[UITextField alloc] init];
        _field.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightRegular];
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [_field setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self.contentView addSubview:_field];

        _eyeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _eyeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [_eyeBtn setTitle:@"显示" forState:UIControlStateNormal];
        [_eyeBtn setTranslatesAutoresizingMaskIntoConstraints:NO];
        [_eyeBtn addTarget:self action:@selector(aweca_toggleEye) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_eyeBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.widthAnchor constraintEqualToConstant:92],
            [_eyeBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_eyeBtn.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_eyeBtn.widthAnchor constraintEqualToConstant:44],
            [_field.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:10],
            [_field.trailingAnchor constraintEqualToAnchor:_eyeBtn.leadingAnchor constant:-6],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)aweca_toggleEye {
    BOOL secure = !self.field.secureTextEntry;
    self.field.secureTextEntry = secure;
    [self.eyeBtn setTitle:(secure ? @"显示" : @"隐藏") forState:UIControlStateNormal];
    if (self.onEyeToggle) self.onEyeToggle(self);
}

@end

#pragma mark - 设置页

@implementation AWECAAPISettingsController {
    AWECATTSManager *_mgr;
    BOOL _tosExpanded;
    BOOL _asrExpanded;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _mgr = [AWECATTSManager shared];
    self.title = @"API 凭证";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorInset = UIEdgeInsetsZero;
    [self.tableView registerClass:[AWECAAPIFieldCell class] forCellReuseIdentifier:@"field"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(aweca_saveAll)];
    _tosExpanded = NO;
    _asrExpanded = NO;
}

#pragma mark - 字段读写

static NSString *AWECATrimStr(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 行模型：tag 标识字段；扩展区的行 index 从固定行之后线性排布
- (void)aweca_applyField:(NSInteger)fieldIndex text:(NSString *)text {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *v = AWECATrimStr(text);
    switch (fieldIndex) {
        case 0: _mgr.appID = v; break;
        case 1: _mgr.accessToken = v; break;
        case 2: _mgr.fishAPIKey = v; break;
        case 3: [ud setObject:v forKey:kAWECATOSAccessKey]; break;
        case 4: [ud setObject:v forKey:kAWECATOSSecretKey]; break;
        case 5: [ud setObject:v forKey:kAWECATOSBucket]; break;
        case 6: [ud setObject:v forKey:kAWECATOSRegion]; break;
        case 7: [ud setObject:v forKey:kAWECAASRResourceId]; break;
        default: break;
    }
}

- (NSString *)aweca_valueForField:(NSInteger)fieldIndex {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    switch (fieldIndex) {
        case 0: return _mgr.appID ?: @"";
        case 1: return _mgr.accessToken ?: @"";
        case 2: return _mgr.fishAPIKey ?: @"";
        case 3: return [ud stringForKey:kAWECATOSAccessKey] ?: @"";
        case 4: return [ud stringForKey:kAWECATOSSecretKey] ?: @"";
        case 5: return [ud stringForKey:kAWECATOSBucket] ?: @"";
        case 6: return [ud stringForKey:kAWECATOSRegion] ?: @"";
        case 7: return [ud stringForKey:kAWECAASRResourceId] ?: @"";
        default: return @"";
    }
}

// 扩展区的第 idx 个字段 -> 全局字段编号（无则 -1）
- (NSInteger)aweca_fieldIndexInExtraRow:(NSInteger)row {
    NSInteger base = 2;   // 两个折叠行
    if (_tosExpanded) {
        if (row >= base && row < base + 4) return 3 + (row - base);   // AK/SK/Bucket/Region
        base += 4;
    }
    if (_asrExpanded) {
        if (row == base) return 7;                                     // 识别资源 ID
    }
    return -1;
}

- (NSString *)aweca_placeholderForField:(NSInteger)f {
    switch (f) {
        case 0: return @"数字 ID";
        case 1: return @"以 AKLT 开头的 Key";
        case 2: return @"fish.audio 的 Key";
        case 3: return @"AccessKey ID";
        case 4: return @"SecretAccessKey";
        case 5: return @"私有桶名称";
        case 6: return @"留空 = cn-beijing";
        case 7: return @"留空 = volc.seedasr.auc";
        default: return @"";
    }
}

- (NSString *)aweca_titleForField:(NSInteger)f {
    switch (f) {
        case 0: return @"App ID";
        case 1: return @"API Key";
        case 2: return @"API Key";
        case 3: return @"AK ID";
        case 4: return @"SK";
        case 5: return @"Bucket";
        case 6: return @"区域";
        case 7: return @"资源 ID";
        default: return @"";
    }
}

- (BOOL)aweca_isSecureField:(NSInteger)f {
    return (f == 1) || (f == 2) || (f == 4);
}

#pragma mark - 保存

- (void)aweca_saveAll {
    [self.view endEditing:YES];
    // 从所有可见 cell 收集当前值（不可见折叠区的值在编辑结束回调里已即时落库，不会丢）
    for (AWECAAPIFieldCell *cell in [self.tableView visibleCells]) {
        if (![cell isKindOfClass:[AWECAAPIFieldCell class]]) continue;
        [self aweca_applyField:cell.eyeBtn.tag text:cell.field.text];
    }
    [_mgr saveConfig];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([AWECATOSUploader hasCredentials]) {
        [AWECAUtils showToast:@"已保存" duration:1.5];
    } else {
        [AWECAUtils showToast:@"已保存（TOS 配置不完整时录音转音色不可用）" duration:2.0];
    }
}

#pragma mark - 表格数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;                       // 火山：App ID + API Key
    if (section == 1) return 1;                       // Fish：API Key
    return 2 + (_tosExpanded ? 4 : 0) + (_asrExpanded ? 1 : 0);   // 高级
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"火山引擎（豆包音色）";
    if (section == 1) return @"FishAudio";
    return @"高级";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"火山引擎控制台 → API Key 管理获取，仅保存在本机。评论区与私聊合成音色都用这一组。";
    if (section == 1) return @"登录 fish.audio → 右上角头像 → API Keys 创建。免费模型 s2.1-pro-free 不消耗余额。";
    return @"TOS 上传用于「录音转音色」的私有桶上传；识别资源 ID 留空即标准版。日常无需展开。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 高级区的折叠入口行
    if (indexPath.section == 2 && indexPath.row < 2) {
        static NSString *foldId = @"fold";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:foldId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:foldId];
        BOOL isTOS = (indexPath.row == 0);
        if (isTOS) {
            cell.textLabel.text = _tosExpanded ? @"∨ 录音转豆包上传（TOS）" : @"› 录音转豆包上传（TOS）";
        } else {
            cell.textLabel.text = _asrExpanded ? @"∨ 标准版语音识别资源 ID" : @"› 标准版语音识别资源 ID";
        }
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    NSInteger f = -1;
    if (indexPath.section == 0) f = indexPath.row;                 // 0/1
    else if (indexPath.section == 1) f = 2;                        // Fish Key
    else f = [self aweca_fieldIndexInExtraRow:indexPath.row];

    AWECAAPIFieldCell *cell = [tableView dequeueReusableCellWithIdentifier:@"field" forIndexPath:indexPath];
    cell.titleLabel.text = [self aweca_titleForField:f];
    cell.field.placeholder = [self aweca_placeholderForField:f];
    cell.field.text = [self aweca_valueForField:f];
    cell.field.secureTextEntry = [self aweca_isSecureField:f];
    cell.eyeBtn.hidden = ![self aweca_isSecureField:f];
    cell.eyeBtn.tag = f;                    // 字段编号随 cell 走，保存时按编号落库
    cell.field.tag = f;
    // 注意：不能 removeTarget（会清掉 cell 内部的明文切换 handler）；
    // UIControl 对相同 target/action 自动去重，重复 addTarget 安全
    [cell.eyeBtn addTarget:self action:@selector(aweca_eyeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cell.field addTarget:self action:@selector(aweca_fieldEdited:) forControlEvents:UIControlEventEditingDidEnd];
    return cell;
}

- (void)aweca_eyeTapped:(UIButton *)sender {
    (void)sender;   // cell 内部已切换明文；此处仅保留目标-动作链路
}

- (void)aweca_fieldEdited:(UITextField *)field {
    [self aweca_applyField:field.tag text:field.text];
    [_mgr saveConfig];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row < 2) {
        if (indexPath.row == 0) _tosExpanded = !_tosExpanded;
        else _asrExpanded = !_asrExpanded;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end
