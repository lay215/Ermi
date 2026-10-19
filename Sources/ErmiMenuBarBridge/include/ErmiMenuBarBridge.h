#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL ErmiVisibilityAvailable(void);
void ErmiVisibilityActivate(NSArray<NSString *> *bundles, void (^completion)(id _Nullable handle, NSError * _Nullable error));
void ErmiVisibilityRelease(id handle);
NS_ASSUME_NONNULL_END
