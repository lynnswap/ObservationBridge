#import "ObservationsCompatObjC.h"
#import <objc/runtime.h>

static char ObservationsCompatLifetimeStoreKey;

@interface ObservationsCompatWeakOwnerBox : NSObject
@property (nonatomic, weak, nullable) id owner;
@end

@implementation ObservationsCompatWeakOwnerBox
@end

static NSLock *ObservationsCompatWeakOwnerLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static NSMutableDictionary<NSNumber *, ObservationsCompatWeakOwnerBox *> *ObservationsCompatWeakOwnerMap(void) {
    static NSMutableDictionary<NSNumber *, ObservationsCompatWeakOwnerBox *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [[NSMutableDictionary alloc] init];
    });
    return map;
}

static uint64_t ObservationsCompatNextWeakOwnerToken(void) {
    static uint64_t token = 1;
    uint64_t current = token;
    token += 1;
    return current;
}

void ObservationsCompatSetLifetimeStore(id owner, id _Nullable store) {
    objc_setAssociatedObject(owner, &ObservationsCompatLifetimeStoreKey, store, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

id _Nullable ObservationsCompatGetLifetimeStore(id owner) {
    return objc_getAssociatedObject(owner, &ObservationsCompatLifetimeStoreKey);
}

uint64_t ObservationsCompatCreateWeakOwnerToken(id owner) {
    NSLock *lock = ObservationsCompatWeakOwnerLock();
    [lock lock];

    uint64_t token = ObservationsCompatNextWeakOwnerToken();
    ObservationsCompatWeakOwnerBox *box = [[ObservationsCompatWeakOwnerBox alloc] init];
    box.owner = owner;
    ObservationsCompatWeakOwnerMap()[@(token)] = box;

    [lock unlock];
    return token;
}

id _Nullable ObservationsCompatGetWeakOwner(uint64_t token) {
    NSLock *lock = ObservationsCompatWeakOwnerLock();
    [lock lock];

    NSNumber *key = @(token);
    ObservationsCompatWeakOwnerBox *box = ObservationsCompatWeakOwnerMap()[key];
    id owner = box.owner;
    if (owner == nil) {
        [ObservationsCompatWeakOwnerMap() removeObjectForKey:key];
    }

    [lock unlock];
    return owner;
}

void ObservationsCompatRemoveWeakOwnerToken(uint64_t token) {
    NSLock *lock = ObservationsCompatWeakOwnerLock();
    [lock lock];
    [ObservationsCompatWeakOwnerMap() removeObjectForKey:@(token)];
    [lock unlock];
}
