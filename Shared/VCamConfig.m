// VCamConfig.m -- Durable configuration layer
#import "VCamConfig.h"
#import "VCamTypes.h"
#import "VCamPaths.h"

@implementation VCamConfig {
    NSMutableDictionary *_dict;
    dispatch_queue_t     _q;
}

+ (instancetype)shared {
    static VCamConfig *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _dict = [NSMutableDictionary dictionary];
    _q    = dispatch_queue_create("com.yiffysec.vcam.config", DISPATCH_QUEUE_SERIAL);
    return self;
}

// -- load / reload / commit ----------------------------------------------
- (void)load {
    [self reload];
}

- (void)reload {
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:VCamConfigPath()];
    dispatch_sync(_q, ^{
        [_dict removeAllObjects];
        if (onDisk) [_dict addEntriesFromDictionary:onDisk];
    });

    // Publish WITHOUT notifying. Listeners call reload in response to the
    // config-changed notification, so notifying here would make every reload
    // trigger another round of reloads in every process -- an endless loop.
    [self publishQuiet:YES];
}

- (void)commit {
    __block NSDictionary *copy;
    dispatch_sync(_q, ^{ copy = [_dict copy]; });

    NSString *configPath = VCamConfigPath();

    [[NSFileManager defaultManager] createDirectoryAtPath:VCamLibraryDir()
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    // Atomic replace so the daemon never observes a half-written plist.
    NSString *tmp = [configPath stringByAppendingPathExtension:@"tmp"];
    if ([copy writeToFile:tmp atomically:YES]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:configPath error:nil];
        [fm moveItemAtPath:tmp toPath:configPath error:nil];
        // World-readable: the daemon runs as a different user.
        [fm setAttributes:@{ NSFilePosixPermissions: @(0644) }
             ofItemAtPath:configPath error:nil];
    } else {
        VCamLogE("VCamConfig: failed to write %{public}@", configPath);
    }

    [self publish];
}

// -- raw access ----------------------------------------------------------
- (id)objectForKey:(NSString *)key {
    if (!key) return nil;
    __block id v = nil;
    dispatch_sync(_q, ^{ v = _dict[key]; });
    return v;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    dispatch_sync(_q, ^{
        if (value) _dict[key] = value;
        else       [_dict removeObjectForKey:key];
    });
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self objectForKey:key];
    return v ? [v boolValue] : def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self objectForKey:key];
    return v ? [v integerValue] : def;
}

- (float)floatForKey:(NSString *)key defaultValue:(float)def {
    id v = [self objectForKey:key];
    return v ? [v floatValue] : def;
}

- (NSString *)stringForKey:(NSString *)key {
    id v = [self objectForKey:key];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

// -- typed properties ----------------------------------------------------
#define VCAM_BOOL_PROP(getter, setter, key, def)                     \
- (BOOL)getter { return [self boolForKey:@key defaultValue:def]; }   \
- (void)setter:(BOOL)v {                                             \
    [self setObject:@(v) forKey:@key];                               \
    [self commit];                                                   \
}

VCAM_BOOL_PROP(enabled,       setEnabled,       kVCamPrefEnabled,      NO)
VCAM_BOOL_PROP(paused,        setPaused,        kVCamPrefPaused,       NO)
VCAM_BOOL_PROP(mirrorH,       setMirrorH,       kVCamPrefMirrorH,      NO)
VCAM_BOOL_PROP(mirrorV,       setMirrorV,       kVCamPrefMirrorV,      NO)
VCAM_BOOL_PROP(hudEnabled,    setHudEnabled,    kVCamPrefHUDEnabled,   YES)
VCAM_BOOL_PROP(audioMuted,    setAudioMuted,    kVCamPrefAudioMuted,   NO)
VCAM_BOOL_PROP(perAppEnabled, setPerAppEnabled, kVCamPrefPerAppEnabled, NO)

#undef VCAM_BOOL_PROP

// Audio mode, with one-time migration from the old useRealAudio boolean so an
// upgrade keeps the user's prior choice: real mic -> Microphone, off -> None.
- (VCamAudioMode)audioMode {
    id raw = [self objectForKey:@kVCamPrefAudioMode];
    if (raw) return (VCamAudioMode)[raw integerValue];

    id legacy = [self objectForKey:@kVCamPrefUseRealAudio];
    if (legacy) return [legacy boolValue] ? VCamAudioMicrophone : VCamAudioNone;

    return VCamAudioMicrophone;   // default: hear the real surroundings
}
- (void)setAudioMode:(VCamAudioMode)m {
    [self setObject:@(m) forKey:@kVCamPrefAudioMode];
    [self commit];
}

- (VCamSourceType)sourceType {
    return (VCamSourceType)[self integerForKey:@kVCamPrefSourceType defaultValue:VCamSourceNone];
}
- (void)setSourceType:(VCamSourceType)t {
    [self setObject:@(t) forKey:@kVCamPrefSourceType];
    [self commit];
}

- (VCamFitMode)fitMode {
    return (VCamFitMode)[self integerForKey:@kVCamPrefFitMode defaultValue:kVCamDefaultFitMode];
}
- (void)setFitMode:(VCamFitMode)m {
    [self setObject:@(m) forKey:@kVCamPrefFitMode];
    [self commit];
}

- (VCamRotation)rotation {
    return (VCamRotation)[self integerForKey:@kVCamPrefRotation defaultValue:kVCamDefaultRotation];
}
- (void)setRotation:(VCamRotation)r {
    [self setObject:@(r) forKey:@kVCamPrefRotation];
    [self commit];
}

- (float)zoom {
    float z = [self floatForKey:@kVCamPrefZoom defaultValue:kVCamDefaultZoom];
    return (z > 0.0f) ? z : kVCamDefaultZoom;
}
- (void)setZoom:(float)z {
    [self setObject:@(MAX(0.1f, z)) forKey:@kVCamPrefZoom];
    [self commit];
}

- (float)panX { return [self floatForKey:@kVCamPrefPanX defaultValue:0.0f]; }
- (void)setPanX:(float)v {
    [self setObject:@(MAX(-1.0f, MIN(1.0f, v))) forKey:@kVCamPrefPanX];
    [self commit];
}

- (float)panY { return [self floatForKey:@kVCamPrefPanY defaultValue:0.0f]; }
- (void)setPanY:(float)v {
    [self setObject:@(MAX(-1.0f, MIN(1.0f, v))) forKey:@kVCamPrefPanY];
    [self commit];
}

- (NSString *)sourcePath { return [self stringForKey:@kVCamPrefSourcePath]; }
- (void)setSourcePath:(NSString *)p {
    [self setObject:p forKey:@kVCamPrefSourcePath];
    [self commit];
    vcam_notify_post(kVCamNotifyMediaChanged);
}

- (NSString *)audioPath { return [self stringForKey:@kVCamPrefAudioPath]; }
- (void)setAudioPath:(NSString *)p {
    [self setObject:p forKey:@kVCamPrefAudioPath];
    [self commit];
    vcam_notify_post(kVCamNotifyMediaChanged);
}

- (NSArray<NSString *> *)perAppList {
    id v = [self objectForKey:@kVCamPrefPerAppList];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}
- (void)setPerAppList:(NSArray<NSString *> *)list {
    [self setObject:(list ?: @[]) forKey:@kVCamPrefPerAppList];
    [self commit];
}

- (BOOL)isAppEnabled:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    if (!self.perAppEnabled) return YES;   // system-wide mode
    return [self.perAppList containsObject:bundleID];
}

- (void)setApp:(NSString *)bundleID enabled:(BOOL)on {
    if (!bundleID.length) return;
    NSMutableArray *list = [self.perAppList mutableCopy];
    if (on) {
        if (![list containsObject:bundleID]) [list addObject:bundleID];
    } else {
        [list removeObject:bundleID];
    }
    self.perAppList = list;
}

// -- publish to shared memory -------------------------------------------
- (VCamSharedState)snapshot {
    VCamSharedState s = {0};
    s.enabled       = self.enabled       ? 1 : 0;
    s.paused        = self.paused        ? 1 : 0;
    s.sourceType    = self.sourceType;
    s.fitMode       = self.fitMode;
    s.rotation      = self.rotation;
    s.zoom          = self.zoom;
    s.panX          = self.panX;
    s.panY          = self.panY;
    s.mirrorH       = self.mirrorH       ? 1 : 0;
    s.mirrorV       = self.mirrorV       ? 1 : 0;
    s.hudEnabled    = self.hudEnabled    ? 1 : 0;
    s.audioMode     = self.audioMode;
    s.audioMuted    = self.audioMuted    ? 1 : 0;
    s.perAppEnabled = self.perAppEnabled ? 1 : 0;
    return s;
}

- (void)publish {
    [self publishQuiet:NO];
}

- (void)publishQuiet:(BOOL)quiet {
    if (vcam_shm_open() != 0) return;

    // Preserve the fields the configuration does not own: HUD liveness belongs
    // to SpringBoard, and the per-app verdict belongs to VCamClient. Stomping
    // either from here would make the daemon briefly act on stale values.
    VCamSharedState live;
    vcam_shm_read(&live);

    VCamSharedState next = [self snapshot];
    next.hudHeartbeat  = live.hudHeartbeat;
    next.hudAlive      = live.hudAlive;
    next.clientAllowed = live.clientAllowed;

    if (quiet) vcam_shm_write_quiet(&next);
    else       vcam_shm_write(&next);
}

@end
