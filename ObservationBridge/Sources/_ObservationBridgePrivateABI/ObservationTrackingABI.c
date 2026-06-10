#include "ObservationBridgePrivateABI.h"

#ifndef __has_attribute
#define __has_attribute(attribute) 0
#endif

#if (defined(__arm64__) || defined(__x86_64__)) && \
    __has_attribute(swiftcall) && __has_attribute(swift_context)
#define OB_HAS_SWIFT_CONTEXT_CALL 1
#else
#define OB_HAS_SWIFT_CONTEXT_CALL 0
#endif

#if OB_HAS_SWIFT_CONTEXT_CALL
typedef void (*OBObservationTrackingCancelFunction)(
    const void *tracking __attribute__((swift_context))
) __attribute__((swiftcall));

typedef void *(*OBObservationTrackingChangedFunction)(
    const void *tracking __attribute__((swift_context))
) __attribute__((swiftcall));
#endif

void OBObservationTrackingCancel(void *function, const void *tracking) {
#if OB_HAS_SWIFT_CONTEXT_CALL
    ((OBObservationTrackingCancelFunction)function)(tracking);
#else
    (void)function;
    (void)tracking;
#endif
}

// Returns the Optional<AnyKeyPath> payload of `ObservationTracking.changed`
// as a single owned (+1) class pointer; NULL means nil.
void *OBObservationTrackingChanged(void *function, const void *tracking) {
#if OB_HAS_SWIFT_CONTEXT_CALL
    return ((OBObservationTrackingChangedFunction)function)(tracking);
#else
    (void)function;
    (void)tracking;
    return 0;
#endif
}
