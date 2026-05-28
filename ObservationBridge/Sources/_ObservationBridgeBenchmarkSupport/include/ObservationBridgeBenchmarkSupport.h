#ifndef OBSERVATION_BRIDGE_BENCHMARK_SUPPORT_H
#define OBSERVATION_BRIDGE_BENCHMARK_SUPPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void ObservationBridgeRuntimeEnqueueHooksInstall(void);
void ObservationBridgeRuntimeEnqueueHooksSetActive(int active);
void ObservationBridgeRuntimeEnqueueHooksReset(void);
uint64_t ObservationBridgeRuntimeEnqueueHooksGlobalCount(void);
uint64_t ObservationBridgeRuntimeEnqueueHooksMainExecutorCount(void);

void ObservationBridgeBenchmarkObservationScopeWaiterRegistered(void);
void ObservationBridgeBenchmarkWaiterRegistrationHooksSetActive(int active);
void ObservationBridgeBenchmarkWaiterRegistrationHooksReset(void);
uint64_t ObservationBridgeBenchmarkWaiterRegistrationHooksCount(void);
int ObservationBridgeBenchmarkWaiterRegistrationHooksWaitForCount(
    uint64_t expectedCount,
    uint64_t timeoutNanoseconds);

#ifdef __cplusplus
}
#endif

#endif
