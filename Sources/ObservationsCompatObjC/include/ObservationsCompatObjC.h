#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void ObservationsCompatSetLifetimeStore(id owner, id _Nullable store);
FOUNDATION_EXPORT id _Nullable ObservationsCompatGetLifetimeStore(id owner);
FOUNDATION_EXPORT uint64_t ObservationsCompatCreateWeakOwnerToken(id owner);
FOUNDATION_EXPORT id _Nullable ObservationsCompatGetWeakOwner(uint64_t token);
FOUNDATION_EXPORT void ObservationsCompatRemoveWeakOwnerToken(uint64_t token);

NS_ASSUME_NONNULL_END
