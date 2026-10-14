#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The text storage's Objective-C primitives. TextKit reads attributes on every run it lays out
/// or fixes, and a Swift override would bridge each dictionary twice; here they pass through untouched.
@interface MDAttributedStorage : NSTextStorage

/// The backing string. Swift subclasses write through it and walk it without bridging.
@property (nonatomic, readonly, strong) NSMutableAttributedString *imp;

@end

NS_ASSUME_NONNULL_END
