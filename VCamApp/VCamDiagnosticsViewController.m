// VCamDiagnosticsViewController.m -- What the daemon is actually doing
#import "VCamDiagnosticsViewController.h"
#import "../Shared/VCamDiagnostics.h"
#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamTypes.h"
#import "../Shared/VCamPaths.h"

#include <signal.h>
#include <errno.h>

// -- A single displayed line ----------------------------------------------
@interface VCamDiagRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *note;     // shown in a second line
@property (nonatomic, strong) UIColor *valueColor;
@end
@implementation VCamDiagRow
+ (VCamDiagRow *)label:(NSString *)l value:(NSString *)v {
    VCamDiagRow *r = [VCamDiagRow new];
    r.label = l; r.value = v;
    return r;
}
+ (VCamDiagRow *)label:(NSString *)l value:(NSString *)v
                  note:(NSString *)n color:(UIColor *)c {
    VCamDiagRow *r = [VCamDiagRow new];
    r.label = l; r.value = v; r.note = n; r.valueColor = c;
    return r;
}
@end

@interface VCamDiagSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray<VCamDiagRow *> *rows;
+ (VCamDiagSection *)header:(NSString *)h footer:(NSString *)f
                       rows:(NSArray *)rows;
@end
@implementation VCamDiagSection
+ (VCamDiagSection *)header:(NSString *)h footer:(NSString *)f
                       rows:(NSArray *)rows {
    VCamDiagSection *s = [VCamDiagSection new];
    s.header = h; s.footer = f; s.rows = rows;
    return s;
}
@end

// -- Hook table -----------------------------------------------------------
typedef struct { uint32_t bit; const char *name; const char *covers; } VCamHookInfo;

static const VCamHookInfo kHooks[] = {
    { kVCamHookEmit,         "BWNodeOutput",                     "every frame; also the fallback route" },
    { kVCamHookImageQueue,   "BWImageQueueSinkNode",             "in-process delivery" },
    { kVCamHookRemoteQueue,  "BWRemoteQueueSinkNode",            "third-party apps" },
    { kVCamHookPhotoEncoder, "BWPhotoEncoderNode",               "photo capture" },
    { kVCamHookStillImage,   "BWStillImageSampleBufferSinkNode", "still delivery" },
    { kVCamHookStillScaler,  "BWStillImageScalerNode",           "photo scaling" },
    { kVCamHookVideoComp,    "BWVideoCompressorNode",            "movie recording" },
    { kVCamHookAudioConv,    "BWAudioConverterNode",             "microphone audio" },
    { kVCamHookDiscovered,   "discovered sinks",                 "runtime class discovery" },
};

@interface VCamDiagnosticsViewController ()
@property (nonatomic, copy) NSArray<VCamDiagSection *> *sections;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation VCamDiagnosticsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(copyReport)];
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Counters move at 30Hz; twice a second is plenty to watch them climb.
    self.refreshTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                        repeats:YES
                                          block:^(NSTimer *t) { [self rebuild]; }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

// -- Model ---------------------------------------------------------------
- (void)rebuild {
    vcam_shm_open();

    VCamDiagnostics d;
    vcam_diag_read(&d);

    VCamSharedState st;
    vcam_shm_read(&st);

    uint32_t attempted = atomic_load(&d.hooksAttempted);
    uint32_t installed = atomic_load(&d.hooksInstalled);
    uint64_t seen      = atomic_load(&d.framesSeen);
    uint64_t replaced  = atomic_load(&d.framesReplaced);
    uint64_t driven    = atomic_load(&d.framesDriven);
    uint32_t tier      = atomic_load(&d.activeTier);
    uint32_t variants  = atomic_load(&d.variantCount);
    uint32_t renders   = atomic_load(&d.renders);
    uint32_t cacheHits = atomic_load(&d.cacheHits);
    uint32_t declined  = atomic_load(&d.declinedFormat);
    uint32_t iosVer    = atomic_load(&d.iosVersion);
    uint32_t lastErr   = atomic_load(&d.lastError);
    uint32_t pid       = atomic_load(&d.daemonPid);

    NSMutableArray<VCamDiagSection *> *out = [NSMutableArray array];

    // ---- Daemon ------------------------------------------------------
    BOOL daemonAlive = (pid != 0) && (kill((pid_t)pid, 0) == 0 || errno == EPERM);

    // The breadcrumb is the key to telling the failure modes apart. The daemon
    // drops it to a plain plist the moment its constructor runs -- before shared
    // memory, which is the thing most likely to fail. So:
    //   no breadcrumb        -> the dylib never loaded into cameracaptured
    //   breadcrumb step<live -> it loaded but stalled (step says where)
    // Unlike the live diagnostics, this survives a shared-memory failure,
    // because it does not live in shared memory.
    NSDictionary *crumb =
        [NSDictionary dictionaryWithContentsOfFile:VCamBreadcrumbPath()];
    NSString *crumbStep = crumb[@"step"];
    NSString *crumbProc = crumb[@"process"];
    NSTimeInterval crumbAge =
        crumb ? ([NSDate date].timeIntervalSince1970 - [crumb[@"at"] doubleValue]) : -1;

    NSString *loadState;
    UIColor  *loadColor;
    NSString *daemonFooter;
    if (daemonAlive) {
        loadState = @"Yes"; loadColor = UIColor.systemGreenColor;
        daemonFooter = nil;
    } else if (crumb) {
        // The dylib definitely loaded -- it wrote this. It just did not finish.
        loadState = [NSString stringWithFormat:@"Loaded, stalled at “%@”",
                     crumbStep ?: @"?"];
        loadColor = UIColor.systemOrangeColor;
        if ([crumbStep isEqualToString:@"shm-failed"]) {
            daemonFooter = @"The dylib injected into the camera daemon but could "
                            "not open its shared memory — a sandbox or permissions "
                            "problem on the shared file, not an injection failure. "
                            "This is the case the jailbreak-root path change is "
                            "meant to fix; if you still see it, the daemon cannot "
                            "reach the file at all.";
        } else if ([crumbStep isEqualToString:@"killswitch"]) {
            daemonFooter = @"The dylib loaded but the boot-loop kill switch is "
                            "engaged. Clear it under Safety on the main screen.";
        } else {
            daemonFooter = @"The dylib injected and started but did not reach the "
                            "running state. The step above is how far it got.";
        }
    } else {
        loadState = @"No"; loadColor = UIColor.systemRedColor;
        daemonFooter = @"No sign the dylib ever loaded into cameracaptured — no "
                        "live report and no startup breadcrumb. The camera daemon "
                        "respawns when a camera app opens; if this stays “No” "
                        "after opening Camera, injection into the daemon is not "
                        "happening. A userspace reboot after install is the usual fix.";
    }

    NSMutableArray<VCamDiagRow *> *daemonRows = [NSMutableArray arrayWithObject:
        [VCamDiagRow label:@"Dylib loaded"
                     value:loadState
                      note:(crumb && !daemonAlive && crumbProc)
                             ? [NSString stringWithFormat:@"in %@, %.0fs ago",
                                 crumbProc, crumbAge]
                             : nil
                     color:loadColor]];

    [daemonRows addObjectsFromArray:@[
        [VCamDiagRow label:@"Reporting live"
                     value:daemonAlive ? @"Yes" : @"No"
                      note:nil
                     color:daemonAlive ? UIColor.systemGreenColor : nil],
        [VCamDiagRow label:@"Process" value:pid ? [NSString stringWithFormat:@"%u", pid]
                                                : @"—"],
        [VCamDiagRow label:@"iOS"
                     value:iosVer ? [NSString stringWithFormat:@"%u.%u",
                                      iosVer >> 16, iosVer & 0xFFFF]
                                  : @"—"],
        [VCamDiagRow label:@"Delivery tier"
                     value:[NSString stringWithFormat:@"%u — %s",
                             tier, vcam_diag_tier_name(tier)]
                      note:tier == VCamTierSinkHooks
                             ? nil
                             : @"Escalated from the preferred route"
                     color:tier == VCamTierSinkHooks ? nil
                                                     : UIColor.systemOrangeColor],
        [VCamDiagRow label:@"Last error"
                     value:[NSString stringWithFormat:@"%s",
                             vcam_diag_error_name(lastErr)]
                      note:nil
                     color:lastErr == VCamDiagErrorNone ? nil
                                                        : UIColor.systemRedColor],
    ]];

    [out addObject:[VCamDiagSection header:@"Camera Daemon"
                                    footer:daemonFooter
                                      rows:daemonRows]];

    // ---- Frames ------------------------------------------------------
    // The headline numbers. Seen with nothing replaced AND nothing declined is
    // the symptom of a real interception failure; declined frames are a
    // deliberate, safe pass-through of a format we will not fake.
    uint64_t declinedCount = atomic_load(&d.framesDeclined);
    uint64_t delivered = replaced + driven;
    BOOL substituting  = delivered > 0;
    NSString *framesFooter;
    if (!st.enabled) {
        framesFooter = @"VCam is off, so no substitution is expected.";
    } else if (st.paused) {
        framesFooter = @"VCam is paused, so the real camera is passing through.";
    } else if (seen == 0) {
        framesFooter = @"No camera frames have been seen at all. Open a camera "
                        "app while this screen is visible and the counters "
                        "should start moving.";
    } else if (!substituting && declinedCount > 0) {
        framesFooter = @"This app asked the camera for a pixel format we do not "
                        "synthesise (often 10-bit HDR or a depth format), so its "
                        "frames are passed through untouched rather than faked — "
                        "which is why it shows the real camera here instead of "
                        "crashing. Declined counts those frames.";
    } else if (!substituting) {
        framesFooter = @"Frames are flowing but none are ours and none were "
                        "declined — a genuine interception miss. Check which "
                        "hooks installed below.";
    } else {
        framesFooter = @"Replaced counts substitutions at a sink. Driven counts "
                        "frames pushed by our own timer when the graph stalled. "
                        "Declined counts frames passed through on purpose.";
    }

    [out addObject:[VCamDiagSection header:@"Frames" footer:framesFooter rows:@[
        [VCamDiagRow label:@"Seen"     value:[self formatCount:seen]],
        [VCamDiagRow label:@"Replaced"
                     value:[self formatCount:replaced]
                      note:nil
                     color:substituting ? UIColor.systemGreenColor
                                        : (seen && st.enabled && !st.paused && !declinedCount
                                            ? UIColor.systemRedColor : nil)],
        [VCamDiagRow label:@"Driven"   value:[self formatCount:driven]],
        [VCamDiagRow label:@"Declined"
                     value:[self formatCount:declinedCount]
                      note:nil
                     color:declinedCount ? UIColor.systemOrangeColor : nil],
    ]]];

    // ---- Hooks -------------------------------------------------------
    NSMutableArray<VCamDiagRow *> *hookRows = [NSMutableArray array];
    int installedCount = 0, attemptedCount = 0;

    for (size_t i = 0; i < VCAM_ARRAY_SIZE(kHooks); i++) {
        BOOL wasAttempted = (attempted & kHooks[i].bit) != 0;
        BOOL isInstalled  = (installed & kHooks[i].bit) != 0;
        if (isInstalled)  installedCount++;
        if (wasAttempted) attemptedCount++;

        NSString *state;
        UIColor  *color;
        if (isInstalled)        { state = @"Installed"; color = UIColor.systemGreenColor; }
        else if (wasAttempted)  { state = @"Failed";    color = UIColor.systemOrangeColor; }
        else                    { state = @"Absent";    color = UIColor.secondaryLabelColor; }

        [hookRows addObject:[VCamDiagRow label:@(kHooks[i].name)
                                         value:state
                                          note:@(kHooks[i].covers)
                                         color:color]];
    }

    // "4 of 6" is more useful than "4": the denominator is how many of these
    // classes exist on this iOS release at all.
    [out addObject:[VCamDiagSection
        header:[NSString stringWithFormat:@"Hooks — %d of %d installed",
                 installedCount, attemptedCount]
        footer:@"\"Absent\" means the class does not exist on this iOS release, "
                "which is expected for some of these. \"Failed\" means it exists "
                "but its signature did not match what we know how to call — "
                "that one is worth reporting."
          rows:hookRows]];

    // ---- Rendering ---------------------------------------------------
    NSString *declinedStr = @"None";
    if (declined) {
        char fourcc[5] = {
            (char)((declined >> 24) & 0xFF), (char)((declined >> 16) & 0xFF),
            (char)((declined >>  8) & 0xFF), (char)( declined        & 0xFF), 0
        };
        for (int i = 0; i < 4; i++) {
            if (fourcc[i] < 32 || fourcc[i] > 126) fourcc[i] = '?';
        }
        declinedStr = @(fourcc);
    }

    [out addObject:[VCamDiagSection
        header:@"Rendering"
        footer:@"Each output shape a client asks for is rendered once per source "
                "frame and cached, so cache hits should far outnumber renders. A "
                "declined format is one we cannot produce — report it."
          rows:@[
        [VCamDiagRow label:@"Pooled shapes" value:[NSString stringWithFormat:@"%u", variants]],
        [VCamDiagRow label:@"Renders"       value:[self formatCount:renders]],
        [VCamDiagRow label:@"Cache hits"    value:[self formatCount:cacheHits]],
        [VCamDiagRow label:@"Declined format"
                     value:declinedStr
                      note:nil
                     color:declined ? UIColor.systemOrangeColor : nil],
    ]]];

    // ---- Configuration echo -----------------------------------------
    // Read back from shared memory rather than the plist, so this confirms what
    // the daemon is actually seeing rather than what the app believes.
    [out addObject:[VCamDiagSection
        header:@"Daemon's View Of Settings"
        footer:@"Read back out of shared memory, so this is what the daemon sees "
                "rather than what this app thinks it set."
          rows:@[
        [VCamDiagRow label:@"Enabled"   value:st.enabled ? @"Yes" : @"No"],
        [VCamDiagRow label:@"Paused"    value:st.paused  ? @"Yes" : @"No"],
        [VCamDiagRow label:@"Source"    value:st.sourceType == VCamSourceVideo ? @"Video"
                                            : st.sourceType == VCamSourcePhoto ? @"Photo"
                                            : @"None"],
        [VCamDiagRow label:@"Per-app"   value:st.perAppEnabled ? @"Yes" : @"No"],
        [VCamDiagRow label:@"Client allowed"
                     value:st.perAppEnabled ? (st.clientAllowed ? @"Yes" : @"No")
                                            : @"n/a (system-wide)"],
        [VCamDiagRow label:@"HUD alive" value:st.hudAlive ? @"Yes" : @"No"],
    ]]];

    // ---- Capture graph ----------------------------------------------
    // Nodes the daemon found. The ones flagged recording-related ([*]) and not
    // marked hooked are the candidates for why a recorded clip still captures
    // the real camera. Full list is in Copy.
    NSString *graph = [NSString stringWithContentsOfFile:VCamGraphDumpPath()
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (graph.length) {
        NSMutableArray<VCamDiagRow *> *graphRows = [NSMutableArray array];
        NSUInteger total = 0;
        for (NSString *line in [graph componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"["]) continue;   // skip comments/blanks
            total++;
            if (![line containsString:@"[*]"]) continue;   // show recording-ish
            // "[R][ ][*] BWSomeNode" -> flags + name
            NSRange sp = [line rangeOfString:@" "];
            if (sp.location == NSNotFound) continue;
            NSString *flags = [line substringToIndex:sp.location];
            NSString *name  = [[line substringFromIndex:sp.location + 1]
                               stringByTrimmingCharactersInSet:
                                   NSCharacterSet.whitespaceCharacterSet];
            BOOL nodeRenders = [flags hasPrefix:@"[R]"];
            [graphRows addObject:
                [VCamDiagRow label:name
                             value:nodeRenders ? @"render" : @"—"
                              note:nil
                             color:nodeRenders ? nil : UIColor.secondaryLabelColor]];
        }
        if (graphRows.count == 0) {
            [graphRows addObject:[VCamDiagRow label:@"No recording-related nodes"
                                             value:@""]];
        }
        [out addObject:[VCamDiagSection
            header:[NSString stringWithFormat:@"Capture Graph — %lu nodes",
                     (unsigned long)total]
            footer:@"Recording-related nodes found on this device. A node marked "
                    "“render” that we do not yet hook is the likely reason a "
                    "recorded video still shows the real camera. Use Copy for the "
                    "full node list."
              rows:graphRows]];
    }

    self.sections = out;
    [self.tableView reloadData];
}

- (NSString *)formatCount:(uint64_t)n {
    static NSNumberFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSNumberFormatter new];
        f.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return [f stringFromNumber:@(n)];
}

// -- Copy a report -------------------------------------------------------
- (void)copyReport {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"Wam Bam VCam diagnostics\n"];
    [s appendFormat:@"app version %@\n\n",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?"];

    for (VCamDiagSection *sec in self.sections) {
        [s appendFormat:@"== %@ ==\n", sec.header];
        for (VCamDiagRow *r in sec.rows) {
            [s appendFormat:@"  %-22s %@\n", r.label.UTF8String, r.value];
        }
        [s appendString:@"\n"];
    }

    // The full capture-graph dump -- every node, not just the recording-related
    // ones shown on screen -- so the whole graph can be read off one copy.
    NSString *graph = [NSString stringWithContentsOfFile:VCamGraphDumpPath()
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (graph.length) {
        [s appendString:@"== Full capture graph ==\n"];
        [s appendString:graph];
        [s appendString:@"\n"];
    }

    UIPasteboard.generalPasteboard.string = s;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Copied"
                         message:@"Diagnostics copied to the clipboard. Paste it "
                                  "into a bug report along with your device and "
                                  "jailbreak."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// -- Table ---------------------------------------------------------------
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.sections.count;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[s].rows.count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sections[s].header;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.sections[s].footer;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    VCamDiagRow *row = self.sections[ip.section].rows[ip.row];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:row.note.length ? UITableViewCellStyleSubtitle
                                      : UITableViewCellStyleValue1
      reuseIdentifier:nil];

    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row.label;

    if (row.note.length) {
        // Subtitle style puts the note under the label, so the value goes in an
        // accessory label on the right.
        cell.detailTextLabel.text      = row.note;
        cell.detailTextLabel.font      =
            [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 0;

        UILabel *v = [[UILabel alloc] init];
        v.text      = row.value;
        v.font      = [UIFont monospacedDigitSystemFontOfSize:14
                                                       weight:UIFontWeightMedium];
        v.textColor = row.valueColor ?: UIColor.secondaryLabelColor;
        [v sizeToFit];
        cell.accessoryView = v;
    } else {
        cell.detailTextLabel.text      = row.value;
        cell.detailTextLabel.font      =
            [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = row.valueColor ?: UIColor.secondaryLabelColor;
    }

    return cell;
}

@end
