#include "ObservationBridgeBenchmarkRuntimeHooks.h"

#include <dlfcn.h>
#include <stdatomic.h>

typedef void *ObservationBridgeRuntimeJob;
typedef void __attribute__((swiftcall)) (*ObservationBridgeRuntimeEnqueueOriginal)(
    ObservationBridgeRuntimeJob job);
typedef void __attribute__((swiftcall)) (*ObservationBridgeRuntimeEnqueueHook)(
    ObservationBridgeRuntimeJob job,
    ObservationBridgeRuntimeEnqueueOriginal original);

static _Atomic int observationBridgeRuntimeEnqueueHooksInstalled = 0;
static _Atomic int observationBridgeRuntimeEnqueueHooksActive = 0;
static _Atomic uint64_t observationBridgeRuntimeGlobalEnqueueCount = 0;
static _Atomic uint64_t observationBridgeRuntimeMainExecutorEnqueueCount = 0;
static ObservationBridgeRuntimeEnqueueHook observationBridgePreviousGlobalEnqueueHook = 0;
static ObservationBridgeRuntimeEnqueueHook observationBridgePreviousMainExecutorEnqueueHook = 0;

static void __attribute__((swiftcall)) observationBridgeGlobalEnqueueHook(
    ObservationBridgeRuntimeJob job,
    ObservationBridgeRuntimeEnqueueOriginal original)
{
    if (atomic_load_explicit(
            &observationBridgeRuntimeEnqueueHooksActive,
            memory_order_relaxed)) {
        atomic_fetch_add_explicit(
            &observationBridgeRuntimeGlobalEnqueueCount,
            1,
            memory_order_relaxed);
    }

    if (observationBridgePreviousGlobalEnqueueHook) {
        observationBridgePreviousGlobalEnqueueHook(job, original);
    } else {
        original(job);
    }
}

static void __attribute__((swiftcall)) observationBridgeMainExecutorEnqueueHook(
    ObservationBridgeRuntimeJob job,
    ObservationBridgeRuntimeEnqueueOriginal original)
{
    if (atomic_load_explicit(
            &observationBridgeRuntimeEnqueueHooksActive,
            memory_order_relaxed)) {
        atomic_fetch_add_explicit(
            &observationBridgeRuntimeMainExecutorEnqueueCount,
            1,
            memory_order_relaxed);
    }

    if (observationBridgePreviousMainExecutorEnqueueHook) {
        observationBridgePreviousMainExecutorEnqueueHook(job, original);
    } else {
        original(job);
    }
}

static ObservationBridgeRuntimeEnqueueHook *
observationBridgeRuntimeEnqueueHookStorage(const char *name)
{
    return (ObservationBridgeRuntimeEnqueueHook *)dlsym(RTLD_DEFAULT, name);
}

void ObservationBridgeRuntimeEnqueueHooksInstall(void)
{
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &observationBridgeRuntimeEnqueueHooksInstalled,
            &expected,
            1,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return;
    }

    ObservationBridgeRuntimeEnqueueHook *globalHook =
        observationBridgeRuntimeEnqueueHookStorage("swift_task_enqueueGlobal_hook");
    if (globalHook) {
        observationBridgePreviousGlobalEnqueueHook = *globalHook;
        *globalHook = observationBridgeGlobalEnqueueHook;
    }

    ObservationBridgeRuntimeEnqueueHook *mainExecutorHook =
        observationBridgeRuntimeEnqueueHookStorage("swift_task_enqueueMainExecutor_hook");
    if (mainExecutorHook) {
        observationBridgePreviousMainExecutorEnqueueHook = *mainExecutorHook;
        *mainExecutorHook = observationBridgeMainExecutorEnqueueHook;
    }
}

void ObservationBridgeRuntimeEnqueueHooksSetActive(int active)
{
    atomic_store_explicit(
        &observationBridgeRuntimeEnqueueHooksActive,
        active ? 1 : 0,
        memory_order_release);
}

void ObservationBridgeRuntimeEnqueueHooksReset(void)
{
    atomic_store_explicit(
        &observationBridgeRuntimeGlobalEnqueueCount,
        0,
        memory_order_relaxed);
    atomic_store_explicit(
        &observationBridgeRuntimeMainExecutorEnqueueCount,
        0,
        memory_order_relaxed);
}

uint64_t ObservationBridgeRuntimeEnqueueHooksGlobalCount(void)
{
    return atomic_load_explicit(
        &observationBridgeRuntimeGlobalEnqueueCount,
        memory_order_relaxed);
}

uint64_t ObservationBridgeRuntimeEnqueueHooksMainExecutorCount(void)
{
    return atomic_load_explicit(
        &observationBridgeRuntimeMainExecutorEnqueueCount,
        memory_order_relaxed);
}
