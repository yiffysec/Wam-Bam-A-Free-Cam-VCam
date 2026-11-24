// VCamPixelConverter.m — Metal-backed pixel format conversion
#import "VCamPixelConverter.h"
#import "VCamTypes.h"
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// ── Metal shader source ───────────────────────────────────────────────────
// BT.709 video-range BGRA → NV12 (420v)
// Y  range: 16–235, Cb/Cr range: 16–240
static NSString *const kBGRA2NV12Shader = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"// BT.709 coefficients, video-range output\n"
"constant float3 kY  = float3( 0.2126f,  0.7152f,  0.0722f);\n"
"constant float3 kCb = float3(-0.1146f, -0.3854f,  0.5000f);\n"
"constant float3 kCr = float3( 0.5000f, -0.4542f, -0.0458f);\n"
"\n"
"kernel void bgra_to_nv12(\n"
"    texture2d<float, access::read>  bgraTex [[texture(0)]],\n"
"    texture2d<float, access::write> yTex    [[texture(1)]],\n"
"    texture2d<float, access::write> uvTex   [[texture(2)]],\n"
"    uint2 gid [[thread_position_in_grid]])\n"
"{\n"
"    uint2 sz = uint2(bgraTex.get_width(), bgraTex.get_height());\n"
"    if (gid.x >= sz.x || gid.y >= sz.y) return;\n"
"\n"
"    // BGRA: .r=B .g=G .b=R .a=A — CIImage and CVPixelBuffer store as BGRA\n"
"    float4 bgra = bgraTex.read(gid);\n"
"    float3 rgb  = float3(bgra.b, bgra.g, bgra.r);  // flip BGR to RGB\n"
"\n"
"    float y  = dot(kY, rgb);\n"
"    float yv = 16.0f/255.0f + y * (219.0f/255.0f);  // video-range Y\n"
"    yTex.write(float4(yv, 0, 0, 1), gid);\n"
"\n"
"    // UV plane is half-resolution; write once per 2×2 block\n"
"    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {\n"
"        // Average 2×2 block for chroma\n"
"        float3 rgb01 = float3(bgraTex.read(gid + uint2(1,0)).bgr);\n"
"        float3 rgb10 = float3(bgraTex.read(gid + uint2(0,1)).bgr);\n"
"        float3 rgb11 = float3(bgraTex.read(gid + uint2(1,1)).bgr);\n"
"        float3 avg   = (rgb + rgb01 + rgb10 + rgb11) * 0.25f;\n"
"\n"
"        float cb = 128.0f/255.0f + dot(kCb, avg) * (224.0f/255.0f);\n"
"        float cr = 128.0f/255.0f + dot(kCr, avg) * (224.0f/255.0f);\n"
"        uvTex.write(float4(cb, cr, 0, 1), gid / 2);\n"
"    }\n"
"}\n";

// ── Implementation ─────────────────────────────────────────────────────────
@interface VCamPixelConverter () {
    id<MTLDevice>              _device;
    id<MTLCommandQueue>        _cmdQueue;
    id<MTLComputePipelineState> _pipelineBGRA2NV12;
    CIContext                 *_ciContext;
    CVMetalTextureCacheRef     _textureCache;
    BOOL                       _ready;
}
@end

@implementation VCamPixelConverter

+ (VCamPixelConverter *)sharedConverter {
    static VCamPixelConverter *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)setup {
    if (_ready) return;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        VCamLogE("VCamPixelConverter: no Metal device");
        return;
    }

    _cmdQueue = [_device newCommandQueue];

    // Compile the BGRA→NV12 kernel
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kBGRA2NV12Shader
                                               options:nil
                                                 error:&err];
    if (!lib || err) {
        VCamLogE("VCamPixelConverter: shader compile error: %@", err);
        return;
    }

    id<MTLFunction> fn = [lib newFunctionWithName:@"bgra_to_nv12"];
    _pipelineBGRA2NV12 = [_device newComputePipelineStateWithFunction:fn error:&err];
    if (!_pipelineBGRA2NV12 || err) {
        VCamLogE("VCamPixelConverter: pipeline error: %@", err);
        return;
    }

    // CIContext — Metal-backed, no color management (we handle color space ourselves)
    NSDictionary *ctxOpts = @{
        kCIContextUseSoftwareRenderer:    @NO,
        kCIContextWorkingColorSpace:      (id)kCFNull,
        kCIContextOutputColorSpace:       (id)kCFNull,
        kCIContextHighQualityDownsample:  @NO,
    };
    _ciContext = [CIContext contextWithMTLDevice:_device options:ctxOpts];

    // Metal texture cache for CVPixelBuffer → MTLTexture conversion
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil, &_textureCache);

    _ready = YES;
    VCamLogI("VCamPixelConverter: Metal setup complete on '%@'", _device.name);
}

- (CIContext *)ciContext {
    return _ciContext;
}

// ── convertToBGRA: ────────────────────────────────────────────────────────
// CIImage-based path: fast, handles arbitrary input formats via CIImage pipeline.
- (CVPixelBufferRef)convertToBGRA:(CVPixelBufferRef)src420v {
    if (!src420v || !_ready) return nil;

    size_t w = CVPixelBufferGetWidth(src420v);
    size_t h = CVPixelBufferGetHeight(src420v);

    CVPixelBufferRef outBGRA = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey:  @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &outBGRA);
    if (!outBGRA) return nil;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src420v];
    [_ciContext render:img toCVPixelBuffer:outBGRA];

    return outBGRA;  // caller releases
}

// ── convertTo420v: ────────────────────────────────────────────────────────
// Metal compute shader path: BT.709 video-range, 2×2 chroma averaging.
- (CVPixelBufferRef)convertTo420v:(CVPixelBufferRef)srcBGRA {
    if (!srcBGRA || !_ready || !_pipelineBGRA2NV12) {
        // Fallback: CIImage path
        CIImage *img = [CIImage imageWithCVPixelBuffer:srcBGRA];
        size_t w = CVPixelBufferGetWidth(srcBGRA);
        size_t h = CVPixelBufferGetHeight(srcBGRA);
        CVPixelBufferRef out = NULL;
        NSDictionary *attrs = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (NSString *)kCVPixelBufferWidthKey:  @(w),
            (NSString *)kCVPixelBufferHeightKey: @(h),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &out);
        if (out) [_ciContext render:img toCVPixelBuffer:out];
        return out;
    }

    size_t w = CVPixelBufferGetWidth(srcBGRA);
    size_t h = CVPixelBufferGetHeight(srcBGRA);

    // Create output NV12 buffer
    CVPixelBufferRef out420v = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferWidthKey:  @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs, &out420v);
    if (!out420v) return nil;

    // Wrap CVPixelBuffers as MTLTextures via cache
    CVMetalTextureRef srcTex  = NULL;
    CVMetalTextureRef yTex    = NULL;
    CVMetalTextureRef uvTex   = NULL;

    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
        srcBGRA, nil, MTLPixelFormatBGRA8Unorm, w, h, 0, &srcTex);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
        out420v, nil, MTLPixelFormatR8Unorm, w, h, 0, &yTex);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
        out420v, nil, MTLPixelFormatRG8Unorm, w/2, h/2, 1, &uvTex);

    if (!srcTex || !yTex || !uvTex) {
        if (srcTex) CFRelease(srcTex);
        if (yTex)   CFRelease(yTex);
        if (uvTex)  CFRelease(uvTex);
        // Fallback to CIImage path
        CIImage *img = [CIImage imageWithCVPixelBuffer:srcBGRA];
        [_ciContext render:img toCVPixelBuffer:out420v];
        return out420v;
    }

    id<MTLCommandBuffer>       cmdBuf  = [_cmdQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc   = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_pipelineBGRA2NV12];
    [enc setTexture:CVMetalTextureGetTexture(srcTex) atIndex:0];
    [enc setTexture:CVMetalTextureGetTexture(yTex)   atIndex:1];
    [enc setTexture:CVMetalTextureGetTexture(uvTex)  atIndex:2];

    MTLSize threads = MTLSizeMake(16, 16, 1);
    MTLSize groups  = MTLSizeMake((w + 15) / 16, (h + 15) / 16, 1);
    [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [enc endEncoding];

    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];  // synchronous for correctness

    CFRelease(srcTex);
    CFRelease(yTex);
    CFRelease(uvTex);

    return out420v;  // caller releases
}

@end
