#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void OBObservationTrackingCancel(void *function, const void *tracking);

void *OBObservationTrackingChanged(void *function, const void *tracking);

#ifdef __cplusplus
}
#endif
