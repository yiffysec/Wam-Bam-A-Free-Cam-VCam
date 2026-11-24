// VCamMainViewController.m -- Companion app root control surface
#import "VCamMainViewController.h"
#import "VCamPerAppViewController.h"
#import "VCamDiagnosticsViewController.h"
#import "../Shared/VCamDiagnostics.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamHUDBridge.h"
#import "../Shared/VCamBootGuard.h"
#import "../Shared/VCamTypes.h"

#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

// -- Row model ------------------------------------------------------------
typedef NS_ENUM(NSInteger, VCamRowKind) {
    VCamRowSwitch,
    VCamRowSegment,
    VCamRowSlider,
    VCamRowDisclosure,
    VCamRowButton,
    VCamRowValue,
};

@interface VCamRow : NSObject
@property (nonatomic, assign) VCamRowKind kind;
@property (nonatomic, copy)   NSString   *title;
@property (nonatomic, copy)   NSString   *subtitle;
@property (nonatomic, copy)   NSArray    *segmentTitles;
@property (nonatomic, copy)   NSArray<NSNumber *> *segmentValues;
@property (nonatomic, assign) float       minValue;
@property (nonatomic, assign) float       maxValue;
@property (nonatomic, assign) BOOL        destructive;
@property (nonatomic, copy)   id        (^get)(void);
@property (nonatomic, copy)   void      (^set)(id value);
@property (nonatomic, copy)   void      (^action)(void);

+ (VCamRow *)switchRow:(NSString *)title
              subtitle:(NSString *)subtitle
                   get:(BOOL (^)(void))get
                   set:(void (^)(BOOL))set;

+ (VCamRow *)segmentRow:(NSString *)title
                 titles:(NSArray *)titles
                 values:(NSArray<NSNumber *> *)values
                    get:(NSInteger (^)(void))get
                    set:(void (^)(NSInteger))set;

+ (VCamRow *)sliderRow:(NSString *)title
                   min:(float)mn
                   max:(float)mx
                   get:(float (^)(void))get
                   set:(void (^)(float))set;

+ (VCamRow *)buttonRow:(NSString *)title
           destructive:(BOOL)destructive
                action:(void (^)(void))action;

+ (VCamRow *)disclosureRow:(NSString *)title
                     value:(NSString * (^)(void))value
                    action:(void (^)(void))action;

+ (VCamRow *)valueRow:(NSString *)title value:(NSString * (^)(void))value;
@end

@implementation VCamRow

+ (VCamRow *)switchRow:(NSString *)title
              subtitle:(NSString *)subtitle
                   get:(BOOL (^)(void))get
                   set:(void (^)(BOOL))set {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowSwitch;
    r.title = title;
    r.subtitle = subtitle;
    r.get = ^id { return @(get()); };
    r.set = ^(id v) { set([v boolValue]); };
    return r;
}

+ (VCamRow *)segmentRow:(NSString *)title
                 titles:(NSArray *)titles
                 values:(NSArray<NSNumber *> *)values
                    get:(NSInteger (^)(void))get
                    set:(void (^)(NSInteger))set {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowSegment;
    r.title = title;
    r.segmentTitles = titles;
    r.segmentValues = values;
    r.get = ^id { return @(get()); };
    r.set = ^(id v) { set([v integerValue]); };
    return r;
}

+ (VCamRow *)sliderRow:(NSString *)title
                   min:(float)mn
                   max:(float)mx
                   get:(float (^)(void))get
                   set:(void (^)(float))set {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowSlider;
    r.title = title;
    r.minValue = mn;
    r.maxValue = mx;
    r.get = ^id { return @(get()); };
    r.set = ^(id v) { set([v floatValue]); };
    return r;
}

+ (VCamRow *)buttonRow:(NSString *)title
           destructive:(BOOL)destructive
                action:(void (^)(void))action {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowButton;
    r.title = title;
    r.destructive = destructive;
    r.action = action;
    return r;
}

+ (VCamRow *)disclosureRow:(NSString *)title
                     value:(NSString * (^)(void))value
                    action:(void (^)(void))action {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowDisclosure;
    r.title = title;
    r.get = ^id { return value ? value() : nil; };
    r.action = action;
    return r;
}

+ (VCamRow *)valueRow:(NSString *)title value:(NSString * (^)(void))value {
    VCamRow *r = [VCamRow new];
    r.kind = VCamRowValue;
    r.title = title;
    r.get = ^id { return value ? value() : nil; };
    return r;
}

@end

// -- Section model --------------------------------------------------------
@interface VCamSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray<VCamRow *> *rows;

+ (VCamSection *)header:(NSString *)h footer:(NSString *)f rows:(NSArray *)rows;
@end

@implementation VCamSection
+ (VCamSection *)header:(NSString *)h footer:(NSString *)f rows:(NSArray *)rows {
    VCamSection *s = [VCamSection new];
    s.header = h; s.footer = f; s.rows = rows;
    return s;
}
@end

// -- View controller ------------------------------------------------------
@interface VCamMainViewController () <PHPickerViewControllerDelegate,
                                       UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<VCamSection *> *sections;
@property (nonatomic, assign) BOOL pickingAudio;
@property (nonatomic, strong) UIView *bannerView;
@property (nonatomic, strong) UILabel *bannerLabel;

- (BOOL)spawnKillall:(const char *)processName;
- (void)alert:(NSString *)title message:(NSString *)message;
@end

@implementation VCamMainViewController {
    int _configToken;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Wam Bam VCam";
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    [[VCamConfig shared] load];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reloadEverything)];

    [self buildBanner];
    [self rebuildSections];

    // React to changes made from the HUD or from Settings.
    __weak typeof(self) weakSelf = self;
    _configToken = vcam_notify_observe(kVCamNotifyConfigChanged,
                                        dispatch_get_main_queue(), ^{
        [[VCamConfig shared] reload];
        [weakSelf rebuildSections];
    });

    [self probeHUD];
}

- (void)dealloc {
    vcam_notify_cancel(_configToken);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[VCamConfig shared] reload];
    [self rebuildSections];
    [self probeHUD];
}

- (void)reloadEverything {
    [[VCamConfig shared] reload];
    [self rebuildSections];
    [self probeHUD];
}

// -- HUD availability banner --------------------------------------------
- (void)buildBanner {
    self.bannerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    self.bannerView.backgroundColor =
        [[UIColor systemOrangeColor] colorWithAlphaComponent:0.14];

    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.numberOfLines = 0;
    self.bannerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.bannerLabel.textColor = [UIColor labelColor];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bannerView addSubview:self.bannerLabel];

    UILayoutGuide *g = self.bannerView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.bannerLabel.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [self.bannerLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [self.bannerLabel.topAnchor      constraintEqualToAnchor:g.topAnchor
                                                         constant:8],
        [self.bannerLabel.bottomAnchor   constraintEqualToAnchor:g.bottomAnchor
                                                         constant:-8],
    ]];
}

- (void)probeHUD {
    __weak typeof(self) weakSelf = self;
    [[VCamHUDBridge shared] probeWithCompletion:^(VCamHUDAvailability a) {
        [weakSelf applyHUDAvailability:a];
    }];
}

- (void)applyHUDAvailability:(VCamHUDAvailability)a {
    NSString *text = [VCamHUDBridge shared].statusDescription;

    if (a == VCamHUDAvailabilityAvailable || !text) {
        self.tableView.tableHeaderView = nil;
    } else {
        self.bannerLabel.text = text;
        CGFloat width = self.tableView.bounds.size.width ?: UIScreen.mainScreen.bounds.size.width;
        CGSize fit = [self.bannerView systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                   withHorizontalFittingPriority:UILayoutPriorityRequired
                                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        self.bannerView.frame = CGRectMake(0, 0, width, MAX(fit.height, 52));
        self.tableView.tableHeaderView = self.bannerView;
    }

    [self rebuildSections];
}

// -- Section construction ------------------------------------------------
- (void)rebuildSections {
    VCamConfig *cfg = [VCamConfig shared];
    VCamHUDBridge *hud = [VCamHUDBridge shared];
    __weak typeof(self) weakSelf = self;

    NSMutableArray<VCamSection *> *s = [NSMutableArray array];

    // ---- Master -------------------------------------------------------
    [s addObject:[VCamSection
        header:@"Virtual Camera"
        footer:@"When enabled, every camera frame handed to apps is replaced with "
                "your media. Pause to let the real camera through without losing "
                "your settings."
          rows:@[
        [VCamRow switchRow:@"Enable VCam"
                  subtitle:nil
                       get:^BOOL { return cfg.enabled; }
                       set:^(BOOL v) {
                           cfg.enabled = v;
                           if (v) cfg.paused = NO;
                           [weakSelf rebuildSections];
                       }],
        [VCamRow switchRow:@"Pause (pass through real camera)"
                  subtitle:nil
                       get:^BOOL { return cfg.paused; }
                       set:^(BOOL v) { cfg.paused = v; [weakSelf rebuildSections]; }],
        [VCamRow valueRow:@"Status" value:^NSString * {
            if (!cfg.enabled)             return @"Off";
            if (cfg.paused)               return @"Paused";
            if (cfg.sourceType == VCamSourceNone) return @"No media selected";

            // "Active" is a claim about the daemon, so check the daemon rather
            // than our own config. Frames flowing with none replaced is the one
            // symptom common to every way substitution silently fails.
            VCamDiagnostics d;
            vcam_diag_read(&d);
            uint64_t seen      = atomic_load(&d.framesSeen);
            uint64_t delivered = atomic_load(&d.framesReplaced) +
                                 atomic_load(&d.framesDriven);
            uint32_t pid       = atomic_load(&d.daemonPid);

            if (pid == 0)                 return @"Daemon not injected";
            if (seen > 0 && delivered == 0) return @"Not substituting";
            if (delivered > 0)            return @"Active";
            return @"Waiting for camera";
        }],
        [VCamRow disclosureRow:@"Diagnostics"
                         value:^NSString * {
            VCamDiagnostics d;
            vcam_diag_read(&d);
            uint32_t tier = atomic_load(&d.activeTier);
            if (atomic_load(&d.daemonPid) == 0) return @"No daemon";
            return tier == VCamTierSinkHooks
                     ? nil
                     : [NSString stringWithFormat:@"tier %u", tier];
        }
                        action:^{
            [weakSelf.navigationController
                pushViewController:[[VCamDiagnosticsViewController alloc] init]
                          animated:YES];
        }],
    ]]];

    // ---- Media --------------------------------------------------------
    NSString *mediaFooter =
        @"Videos loop seamlessly at 30 fps. Photos are delivered as a still frame. "
         "Media is copied into the tweak's own directory, so deleting it from Photos "
         "afterwards is fine.";

    [s addObject:[VCamSection header:@"Media Source" footer:mediaFooter rows:@[
        [VCamRow disclosureRow:@"Choose Video or Photo"
                         value:^NSString * {
            NSString *p = cfg.sourcePath;
            if (!p.length) return @"None";
            return p.lastPathComponent;
        }
                        action:^{ [weakSelf presentMediaPicker]; }],
        [VCamRow disclosureRow:@"Import From Files"
                         value:nil
                        action:^{ [weakSelf presentDocumentPickerForAudio:NO]; }],
        [VCamRow valueRow:@"Detected Type" value:^NSString * {
            switch (cfg.sourceType) {
                case VCamSourceVideo: return @"Video";
                case VCamSourcePhoto: return @"Photo";
                default:              return @"—";
            }
        }],
        [VCamRow buttonRow:@"Clear Media"
               destructive:YES
                    action:^{ [weakSelf clearMedia]; }],
    ]]];

    // ---- Geometry -----------------------------------------------------
    [s addObject:[VCamSection
        header:@"Framing"
        footer:@"Fill crops your media to the camera's aspect ratio so no black bars "
                "are ever visible. Fit letterboxes instead. Rotation is applied before "
                "fitting, so use 90° or 270° for landscape footage on a portrait camera."
          rows:@[
        [VCamRow segmentRow:@"Fit Mode"
                     titles:@[@"Fill", @"Fit", @"Stretch"]
                     values:@[@(VCamFitFill), @(VCamFitFit), @(VCamFitStretch)]
                        get:^NSInteger { return cfg.fitMode; }
                        set:^(NSInteger v) { cfg.fitMode = (VCamFitMode)v; }],
        [VCamRow segmentRow:@"Rotation"
                     titles:@[@"0°", @"90°", @"180°", @"270°"]
                     values:@[@0, @90, @180, @270]
                        get:^NSInteger { return cfg.rotation; }
                        set:^(NSInteger v) { cfg.rotation = (VCamRotation)v; }],
        [VCamRow switchRow:@"Mirror Horizontally"
                  subtitle:@"Match the front camera's mirrored preview"
                       get:^BOOL { return cfg.mirrorH; }
                       set:^(BOOL v) { cfg.mirrorH = v; }],
        [VCamRow switchRow:@"Mirror Vertically"
                  subtitle:nil
                       get:^BOOL { return cfg.mirrorV; }
                       set:^(BOOL v) { cfg.mirrorV = v; }],
        [VCamRow sliderRow:@"Zoom"
                       min:1.0f max:4.0f
                       get:^float { return cfg.zoom; }
                       set:^(float v) { cfg.zoom = v; }],
        [VCamRow sliderRow:@"Pan X"
                       min:-1.0f max:1.0f
                       get:^float { return cfg.panX; }
                       set:^(float v) { cfg.panX = v; }],
        [VCamRow sliderRow:@"Pan Y"
                       min:-1.0f max:1.0f
                       get:^float { return cfg.panY; }
                       set:^(float v) { cfg.panY = v; }],
        [VCamRow buttonRow:@"Reset Framing"
               destructive:NO
                    action:^{
                        cfg.rotation = VCamRotation0;
                        cfg.mirrorH  = NO;
                        cfg.mirrorV  = NO;
                        cfg.zoom     = 1.0f;
                        cfg.panX     = 0.0f;
                        cfg.panY     = 0.0f;
                        cfg.fitMode  = VCamFitFill;
                        [weakSelf rebuildSections];
                    }],
    ]]];

    // ---- Audio --------------------------------------------------------
    [s addObject:[VCamSection
        header:@"Audio"
        footer:@"With the real microphone on, apps hear your surroundings while seeing "
                "your media. Turn it off and supply a file to replace the microphone too."
          rows:@[
        [VCamRow switchRow:@"Use Real Microphone"
                  subtitle:nil
                       get:^BOOL { return cfg.useRealAudio; }
                       set:^(BOOL v) { cfg.useRealAudio = v; [weakSelf rebuildSections]; }],
        [VCamRow disclosureRow:@"Custom Audio File"
                         value:^NSString * {
            NSString *p = cfg.audioPath;
            return p.length ? p.lastPathComponent : @"None";
        }
                        action:^{ [weakSelf presentDocumentPickerForAudio:YES]; }],
    ]]];

    // ---- Targeting ----------------------------------------------------
    [s addObject:[VCamSection
        header:@"App Targeting"
        footer:@"System-wide replaces the camera everywhere. Per-app mode leaves the "
                "real camera intact except in the apps you pick."
          rows:@[
        [VCamRow switchRow:@"Per-App Mode"
                  subtitle:@"Off = system-wide"
                       get:^BOOL { return cfg.perAppEnabled; }
                       set:^(BOOL v) { cfg.perAppEnabled = v; [weakSelf rebuildSections]; }],
        [VCamRow disclosureRow:@"Enabled Apps"
                         value:^NSString * {
            NSUInteger n = cfg.perAppList.count;
            return n ? [NSString stringWithFormat:@"%lu", (unsigned long)n] : @"None";
        }
                        action:^{
            VCamPerAppViewController *vc = [[VCamPerAppViewController alloc] init];
            [weakSelf.navigationController pushViewController:vc animated:YES];
        }],
    ]]];

    // ---- HUD ----------------------------------------------------------
    NSString *hudFooter;
    switch (hud.availability) {
        case VCamHUDAvailabilityAvailable:
            hudFooter = @"The SpringBoard HUD is responding. It gives you a draggable "
                         "on/off control over every app.";
            break;
        case VCamHUDAvailabilityUnavailable:
            hudFooter = @"The HUD did not answer, so this app is driving everything. "
                         "You can still force the toggle below — detection can be "
                         "wrong on unusual jailbreak setups, and flipping it does no harm.";
            break;
        default:
            hudFooter = @"Checking for the SpringBoard HUD…";
            break;
    }

    [s addObject:[VCamSection header:@"SpringBoard HUD" footer:hudFooter rows:@[
        [VCamRow valueRow:@"Availability" value:^NSString * {
            switch ([VCamHUDBridge shared].availability) {
                case VCamHUDAvailabilityAvailable:   return @"Responding";
                case VCamHUDAvailabilityUnavailable: return @"Not responding";
                default:                             return @"Checking…";
            }
        }],
        [VCamRow switchRow:@"Show HUD"
                  subtitle:@"Manual override"
                       get:^BOOL { return cfg.hudEnabled; }
                       set:^(BOOL v) {
            cfg.hudEnabled = v;
            [[VCamHUDBridge shared] requestHUDVisible:v];
            [weakSelf rebuildSections];
        }],
        [VCamRow buttonRow:@"Re-check HUD"
               destructive:NO
                    action:^{ [weakSelf probeHUD]; }],
    ]]];

    // ---- Safety -------------------------------------------------------
    BOOL killed = vcam_bootguard_is_killed();
    [s addObject:[VCamSection
        header:@"Safety"
        footer:@"If cameracaptured crashes three times in a row the tweak disables "
                "itself rather than risk a boot loop. Clear the kill switch here once "
                "you have changed whatever caused it."
          rows:@[
        [VCamRow valueRow:@"Kill Switch" value:^NSString * {
            return vcam_bootguard_is_killed() ? @"ENGAGED" : @"Clear";
        }],
        [VCamRow buttonRow:killed ? @"Clear Kill Switch" : @"Engage Kill Switch"
               destructive:!killed
                    action:^{
            if (vcam_bootguard_is_killed()) vcam_bootguard_clear_killed();
            else                            vcam_bootguard_set_killed();
            [weakSelf rebuildSections];
        }],
        [VCamRow buttonRow:@"Restart Camera Daemon"
               destructive:YES
                    action:^{ [weakSelf confirmRestartDaemon]; }],
    ]]];

    self.sections = s;
    [self.tableView reloadData];
}

// -- Media import --------------------------------------------------------
- (void)presentMediaPicker {
    PHPickerConfiguration *conf = [[PHPickerConfiguration alloc] init];
    conf.selectionLimit = 1;
    conf.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.videosFilter, PHPickerFilter.imagesFilter
    ]];
    if (@available(iOS 15.0, *)) {
        conf.preferredAssetRepresentationMode =
            PHPickerConfigurationAssetRepresentationModeCurrent;
    }

    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:conf];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;

    NSItemProvider *ip = results.firstObject.itemProvider;

    BOOL isVideo = [ip hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
    NSString *typeID = isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;

    [self showProgress:@"Importing…"];

    __weak typeof(self) weakSelf = self;
    [ip loadFileRepresentationForTypeIdentifier:typeID
                              completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf dismissProgressThen:^{
                    [weakSelf showError:error.localizedDescription
                                          ?: @"The picker returned no file."];
                }];
            });
            return;
        }
        NSString *dest = [weakSelf importFileAtURL:url
                                          asVideo:isVideo
                                            audio:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf dismissProgressThen:^{
                if (dest) {
                    VCamConfig *cfg = [VCamConfig shared];
                    cfg.sourceType = isVideo ? VCamSourceVideo : VCamSourcePhoto;
                    cfg.sourcePath = dest;
                    [weakSelf rebuildSections];
                } else {
                    [weakSelf showError:@"Could not copy the file into the tweak's directory."];
                }
            }];
        });
    }];
}

- (void)presentDocumentPickerForAudio:(BOOL)audio {
    self.pickingAudio = audio;
    NSArray<UTType *> *types = audio
        ? @[UTTypeAudio]
        : @[UTTypeMovie, UTTypeImage];

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                   asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    NSURL *url = urls.firstObject;
    BOOL audio = self.pickingAudio;

    BOOL isVideo = NO;
    if (!audio) {
        NSString *ext = url.pathExtension.lowercaseString;
        isVideo = [@[@"mov", @"mp4", @"m4v"] containsObject:ext];
    }

    NSString *dest = [self importFileAtURL:url asVideo:isVideo audio:audio];
    if (!dest) {
        [self showError:@"Could not copy that file."];
        return;
    }

    VCamConfig *cfg = [VCamConfig shared];
    if (audio) {
        cfg.audioPath    = dest;
        cfg.useRealAudio = NO;
    } else {
        cfg.sourceType = isVideo ? VCamSourceVideo : VCamSourcePhoto;
        cfg.sourcePath = dest;
    }
    [self rebuildSections];
}

/// Copies a picked file into the tweak directory using write-to-temp +
/// atomic replace, so the daemon never opens a half-written file.
- (NSString *)importFileAtURL:(NSURL *)src asVideo:(BOOL)isVideo audio:(BOOL)audio {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:@kVCamLibraryDir
  withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *ext = src.pathExtension.length ? src.pathExtension
                                              : (isVideo ? @"mov" : @"jpg");
    NSString *base = audio ? @kVCamLibraryDir "/audio" : @kVCamMediaPath;
    NSString *dest = [base stringByAppendingPathExtension:ext];
    NSString *tmp  = [dest stringByAppendingPathExtension:@"part"];

    BOOL scoped = [src startAccessingSecurityScopedResource];

    [fm removeItemAtPath:tmp error:nil];
    NSError *err = nil;
    BOOL ok = [fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:tmp] error:&err];

    if (scoped) [src stopAccessingSecurityScopedResource];

    if (!ok) {
        VCamLogE("import: copy failed: %{public}@", err);
        return nil;
    }

    // Remove any previously imported media with a different extension so the
    // daemon's extension probe cannot pick up a stale file.
    NSArray *allExts = audio
        ? @[@"m4a", @"mp3", @"wav", @"aac", @"caf"]
        : @[@"mov", @"mp4", @"m4v", @"jpg", @"jpeg", @"png", @"heic"];
    for (NSString *e in allExts) {
        NSString *old = [base stringByAppendingPathExtension:e];
        if (![old isEqualToString:dest]) [fm removeItemAtPath:old error:nil];
    }

    [fm removeItemAtPath:dest error:nil];
    if (![fm moveItemAtPath:tmp toPath:dest error:&err]) {
        VCamLogE("import: atomic move failed: %{public}@", err);
        return nil;
    }

    [fm setAttributes:@{ NSFilePosixPermissions: @(0644) }
         ofItemAtPath:dest error:nil];

    vcam_notify_post(kVCamNotifyMediaChanged);
    return dest;
}

- (void)clearMedia {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *e in @[@"mov", @"mp4", @"m4v", @"jpg", @"jpeg", @"png", @"heic"]) {
        [fm removeItemAtPath:[@kVCamMediaPath stringByAppendingPathExtension:e]
                       error:nil];
    }
    VCamConfig *cfg = [VCamConfig shared];
    cfg.sourcePath = nil;
    cfg.sourceType = VCamSourceNone;
    vcam_notify_post(kVCamNotifyMediaChanged);
    [self rebuildSections];
}

// -- Daemon restart ------------------------------------------------------
- (void)confirmRestartDaemon {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Restart Camera Daemon"
                         message:@"Any app currently using the camera will drop its "
                                  "session. This is the quickest way to apply a change "
                                  "the daemon seems to have missed."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Restart"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        // Killing the daemon makes launchd respawn it, which re-runs injection.
        // posix_spawn rather than system(): system() is marked unavailable in
        // the iOS SDK and will not compile.
        BOOL ok = [weakSelf spawnKillall:"cameracaptured"]
                | [weakSelf spawnKillall:"mediaserverd"];
        if (!ok) {
            [weakSelf alert:@"Could Not Restart"
                    message:@"The daemon could not be signalled from here. "
                             "Toggling VCam off and on, or a respring, has the "
                             "same effect."];
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/// Runs `killall -9 <name>`. Returns YES if the child was spawned and exited 0.
- (BOOL)spawnKillall:(const char *)processName {
    const char *killall = "/usr/bin/killall";
    if (access(killall, X_OK) != 0) {
        killall = "/var/jb/usr/bin/killall";          // rootless
        if (access(killall, X_OK) != 0) {
            killall = "/usr/bin/killall";             // roothide rewrites this
        }
    }

    char *const argv[] = { (char *)"killall", (char *)"-9",
                           (char *)processName, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, killall, NULL, NULL, argv, environ);
    if (rc != 0) {
        VCamLogE("restart: posix_spawn(%{public}s) rc=%d", processName, rc);
        return NO;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// -- Alerts / progress ---------------------------------------------------
- (void)showProgress:(NSString *)message {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:nil message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)dismissProgressThen:(void (^)(void))then {
    UIViewController *presented = self.presentedViewController;
    if ([presented isKindOfClass:UIAlertController.class]) {
        [presented dismissViewControllerAnimated:YES completion:then];
    } else if (then) {
        then();
    }
}

- (void)showError:(NSString *)message {
    [self alert:@"Import Failed" message:message];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:title message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

// -- Table data source ---------------------------------------------------
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sections[s].header;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.sections[s].footer;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    VCamRow *row = self.sections[ip.section].rows[ip.row];

    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (row.kind) {
        case VCamRowSwitch: {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [row.get() boolValue];
            sw.tag = ip.section * 1000 + ip.row;
            [sw addTarget:self action:@selector(switchChanged:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            if (row.subtitle.length) cell.detailTextLabel.text = row.subtitle;
            break;
        }
        case VCamRowSegment: {
            UISegmentedControl *seg =
                [[UISegmentedControl alloc] initWithItems:row.segmentTitles];
            NSInteger current = [row.get() integerValue];
            NSUInteger idx = [row.segmentValues indexOfObject:@(current)];
            seg.selectedSegmentIndex = (idx == NSNotFound) ? 0 : idx;
            seg.tag = ip.section * 1000 + ip.row;
            [seg addTarget:self action:@selector(segmentChanged:)
                forControlEvents:UIControlEventValueChanged];

            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UILabel *label = [[UILabel alloc] init];
            label.text = row.title;
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            seg.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:label];
            [cell.contentView addSubview:seg];
            UILayoutGuide *g = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
                [label.topAnchor     constraintEqualToAnchor:g.topAnchor],
                [seg.leadingAnchor   constraintEqualToAnchor:g.leadingAnchor],
                [seg.trailingAnchor  constraintEqualToAnchor:g.trailingAnchor],
                [seg.topAnchor       constraintEqualToAnchor:label.bottomAnchor
                                                    constant:8],
                [seg.bottomAnchor    constraintEqualToAnchor:g.bottomAnchor],
            ]];
            break;
        }
        case VCamRowSlider: {
            float value = [row.get() floatValue];
            UISlider *sl = [[UISlider alloc] init];
            sl.minimumValue = row.minValue;
            sl.maximumValue = row.maxValue;
            sl.value = value;
            sl.tag = ip.section * 1000 + ip.row;
            sl.continuous = YES;
            [sl addTarget:self action:@selector(sliderChanged:)
                forControlEvents:UIControlEventValueChanged];

            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UILabel *label = [[UILabel alloc] init];
            label.text = [NSString stringWithFormat:@"%@  %.2f", row.title, value];
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            label.textColor = [UIColor secondaryLabelColor];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            sl.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:label];
            [cell.contentView addSubview:sl];
            UILayoutGuide *g = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
                [label.topAnchor     constraintEqualToAnchor:g.topAnchor],
                [sl.leadingAnchor    constraintEqualToAnchor:g.leadingAnchor],
                [sl.trailingAnchor   constraintEqualToAnchor:g.trailingAnchor],
                [sl.topAnchor        constraintEqualToAnchor:label.bottomAnchor
                                                    constant:4],
                [sl.bottomAnchor     constraintEqualToAnchor:g.bottomAnchor],
            ]];
            break;
        }
        case VCamRowDisclosure: {
            cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            id v = row.get ? row.get() : nil;
            cell.detailTextLabel.text = [v isKindOfClass:NSString.class] ? v : nil;
            break;
        }
        case VCamRowButton: {
            cell.textLabel.textColor = row.destructive
                ? [UIColor systemRedColor]
                : [UIColor systemBlueColor];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
        case VCamRowValue: {
            id v = row.get ? row.get() : nil;
            cell.detailTextLabel.text = [v isKindOfClass:NSString.class] ? v : nil;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            break;
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    VCamRow *row = self.sections[ip.section].rows[ip.row];
    if (row.action) row.action();
}

// -- Control targets -----------------------------------------------------
- (VCamRow *)rowForTag:(NSInteger)tag {
    NSInteger section = tag / 1000;
    NSInteger index   = tag % 1000;
    if (section >= (NSInteger)self.sections.count) return nil;
    NSArray *rows = self.sections[section].rows;
    if (index >= (NSInteger)rows.count) return nil;
    return rows[index];
}

- (void)switchChanged:(UISwitch *)sw {
    VCamRow *row = [self rowForTag:sw.tag];
    if (row.set) row.set(@(sw.isOn));
}

- (void)segmentChanged:(UISegmentedControl *)seg {
    VCamRow *row = [self rowForTag:seg.tag];
    if (!row) return;
    NSInteger idx = seg.selectedSegmentIndex;
    if (idx < 0 || idx >= (NSInteger)row.segmentValues.count) return;
    if (row.set) row.set(row.segmentValues[idx]);
}

- (void)sliderChanged:(UISlider *)sl {
    VCamRow *row = [self rowForTag:sl.tag];
    if (row.set) row.set(@(sl.value));

    // Live-update the label without rebuilding the whole table.
    UIView *v = sl;
    while (v && ![v isKindOfClass:UITableViewCell.class]) v = v.superview;
    UITableViewCell *cell = (UITableViewCell *)v;
    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:UILabel.class]) {
            ((UILabel *)sub).text =
                [NSString stringWithFormat:@"%@  %.2f", row.title, sl.value];
            break;
        }
    }
}

@end
