// Protocol reference: Dwarves Foundation Hidden Bar (MIT), see docs/research/hidden-bar-LICENSE.
#import "ErmiMenuBarBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

// macOS 27 已移除加宽分隔符的效果；动态探测私有接口，系统变更时明确退回可见状态。
static SEL configurationSelector(void) { return NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"); }
static SEL activateSelector(void) { return NSSelectorFromString(@"activateWithConfiguration:completionHandler:"); }
BOOL ErmiVisibilityAvailable(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL); });
    return framework && [NSClassFromString(@"MBAssessmentModeConfiguration") instancesRespondToSelector:configurationSelector()]
        && [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:activateSelector()]
        && [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:@selector(invalidate)];
}
void ErmiVisibilityActivate(NSArray<NSString *> *bundles, void (^completion)(id, NSError *)) {
    void (^finish)(id, NSError *) = ^(id handle, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, error); });
    };
    @try {
        if (!ErmiVisibilityAvailable()) @throw [NSException exceptionWithName:@"Unavailable" reason:@"当前系统不支持菜单栏折叠接口" userInfo:nil];
        // 系统控件始终保留；接口要求 NSArray，不能用 NSSet 替代。
        NSMutableArray *systemItems = [NSMutableArray array];
        for (NSInteger i = 0; i < 64; i++) [systemItems addObject:@(i)];
        id config = ((id (*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"MBAssessmentModeConfiguration") alloc], configurationSelector(), systemItems, bundles);
        id handle = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!config || !handle) @throw [NSException exceptionWithName:@"Unavailable" reason:@"无法创建菜单栏配置" userInfo:nil];
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(handle, activateSelector(), config, ^(NSError *error) {
            if (error) ErmiVisibilityRelease(handle);
            finish(error ? nil : handle, error);
        });
    } @catch (NSException *exception) {
        finish(nil, [NSError errorWithDomain:@"ErmiMenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"菜单栏接口不可用"}]);
    }
}
void ErmiVisibilityRelease(id handle) {
    // 系统 API 签名可能变化，异常不跨越 Swift 边界。
    @try { if ([handle respondsToSelector:@selector(invalidate)]) ((void (*)(id, SEL))objc_msgSend)(handle, @selector(invalidate)); }
    @catch (NSException *exception) { NSLog(@"Ermi menu bar restore: %@", exception.reason); }
}
