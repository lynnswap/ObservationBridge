#ifndef OBSERVATION_BRIDGE_BENCHMARK_RUNTIME_HOOKS_H
#define OBSERVATION_BRIDGE_BENCHMARK_RUNTIME_HOOKS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void ObservationBridgeRuntimeEnqueueHooksInstall(void);
void ObservationBridgeRuntimeEnqueueHooksSetActive(int active);
void ObservationBridgeRuntimeEnqueueHooksReset(void);
uint64_t ObservationBridgeRuntimeEnqueueHooksGlobalCount(void);
uint64_t ObservationBridgeRuntimeEnqueueHooksMainExecutorCount(void);

#ifdef __cplusplus
}
#endif

#endif
