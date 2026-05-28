#include "ObservationBridgeBenchmarkSupport.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

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

static _Atomic int observationBridgeBenchmarkWaiterRegistrationHooksActive = 0;
static pthread_mutex_t observationBridgeBenchmarkWaiterRegistrationMutex =
    PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t observationBridgeBenchmarkWaiterRegistrationCondition =
    PTHREAD_COND_INITIALIZER;
static uint64_t observationBridgeBenchmarkWaiterRegistrationCount = 0;

void ObservationBridgeBenchmarkObservationScopeWaiterRegistered(void)
{
    if (!atomic_load_explicit(
            &observationBridgeBenchmarkWaiterRegistrationHooksActive,
            memory_order_acquire)) {
        return;
    }

    pthread_mutex_lock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    observationBridgeBenchmarkWaiterRegistrationCount += 1;
    pthread_cond_broadcast(&observationBridgeBenchmarkWaiterRegistrationCondition);
    pthread_mutex_unlock(&observationBridgeBenchmarkWaiterRegistrationMutex);
}

void ObservationBridgeBenchmarkWaiterRegistrationHooksSetActive(int active)
{
    atomic_store_explicit(
        &observationBridgeBenchmarkWaiterRegistrationHooksActive,
        active ? 1 : 0,
        memory_order_release);
}

void ObservationBridgeBenchmarkWaiterRegistrationHooksReset(void)
{
    pthread_mutex_lock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    observationBridgeBenchmarkWaiterRegistrationCount = 0;
    pthread_mutex_unlock(&observationBridgeBenchmarkWaiterRegistrationMutex);
}

uint64_t ObservationBridgeBenchmarkWaiterRegistrationHooksCount(void)
{
    pthread_mutex_lock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    uint64_t count = observationBridgeBenchmarkWaiterRegistrationCount;
    pthread_mutex_unlock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    return count;
}

static struct timespec observationBridgeBenchmarkDeadline(uint64_t timeoutNanoseconds)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);

    deadline.tv_sec += (time_t)(timeoutNanoseconds / 1000000000ULL);
    deadline.tv_nsec += (long)(timeoutNanoseconds % 1000000000ULL);
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    return deadline;
}

int ObservationBridgeBenchmarkWaiterRegistrationHooksWaitForCount(
    uint64_t expectedCount,
    uint64_t timeoutNanoseconds)
{
    struct timespec deadline = observationBridgeBenchmarkDeadline(timeoutNanoseconds);

    pthread_mutex_lock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    while (observationBridgeBenchmarkWaiterRegistrationCount < expectedCount) {
        int result = pthread_cond_timedwait(
            &observationBridgeBenchmarkWaiterRegistrationCondition,
            &observationBridgeBenchmarkWaiterRegistrationMutex,
            &deadline);
        if (result == ETIMEDOUT) {
            pthread_mutex_unlock(&observationBridgeBenchmarkWaiterRegistrationMutex);
            return 0;
        }
    }

    pthread_mutex_unlock(&observationBridgeBenchmarkWaiterRegistrationMutex);
    return 1;
}
