#import "MDAttributedStorage.h"

@implementation MDAttributedStorage

- (instancetype)init {
    self = [super init];
    if (self) {
        _imp = [[NSMutableAttributedString alloc] init];
    }
    return self;
}

- (NSUInteger)length {
    return _imp.length;
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)location effectiveRange:(nullable NSRangePointer)range {
    if (location < _imp.length) {
        return [_imp attributesAtIndex:location effectiveRange:range];
    }
    if (range) {
        *range = NSMakeRange(NSNotFound, 0);
    }
    return @{};
}

@end
