// MultiAudio virtual output device: a Core Audio AudioServerPlugIn loaded by coreaudiod.
//
// It exists to tell video players how late audio will be. Apps play to this device, and the
// device reports MultiAudio's delay as its latency, so players hold back video to match.
// Its own output is discarded: MultiAudio's process tap captures what apps play.
//
// MultiAudio sets the latency through a custom property (kPropertyLatencyFrames).

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectDevice = 2,
    kObjectStream = 3,
};

#define kDeviceUID CFSTR("MultiAudioDevice_UID")
#define kModelUID CFSTR("MultiAudioDevice_ModelUID")
static const Float64 kSampleRate = 48000;
static const UInt32 kChannels = 2;
static const UInt32 kZeroPeriodFrames = 16384; // how often GetZeroTimeStamp's anchor advances
static const UInt32 kMaxLatencyFrames = 480000; // 10 s
static const AudioObjectPropertySelector kPropertyLatencyFrames = 'mlat';

static AudioServerPlugInHostRef sHost;
static pthread_mutex_t sStateLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t sClockLock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint sRefCount;
static atomic_uint sLatencyFrames;
static UInt32 sIOClients; // guarded by sStateLock
static Float64 sTicksPerFrame;
static UInt64 sAnchorHostTime; // these two guarded by sClockLock
static UInt64 sPeriodsElapsed;

static AudioStreamBasicDescription streamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = kChannels * sizeof(Float32);
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// MARK: Properties
//
// One function answers has/size/get: `data` is NULL when only the size is wanted, and
// kAudioHardwareUnknownPropertyError means the object doesn't have the property.

#define PUT(T, v) do { \
        if (outSize) *outSize = sizeof(T); \
        if (data) { if (maxSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T *)data = (v); } \
        return noErr; \
    } while (0)
#define PUT_NOTHING() do { if (outSize) *outSize = 0; return noErr; } while (0)

static OSStatus plugInProperty(const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                               UInt32 maxSize, UInt32 *outSize, void *data) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("MultiAudio"));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: PUT(AudioObjectID, kObjectDevice);
    case kAudioPlugInPropertyBoxList: PUT_NOTHING();
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
        Boolean match = CFEqual(*(CFStringRef *)qualifier, kDeviceUID);
        PUT(AudioObjectID, match ? kObjectDevice : kAudioObjectUnknown);
    }
    case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus deviceProperty(const AudioObjectPropertyAddress *a, UInt32 maxSize, UInt32 *outSize, void *data) {
    Boolean output = a->mScope == kAudioObjectPropertyScopeOutput || a->mScope == kAudioObjectPropertyScopeGlobal;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectPlugIn);
    case kAudioObjectPropertyName: PUT(CFStringRef, CFSTR("MultiAudio"));
    case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("MultiAudio"));
    case kAudioDevicePropertyDeviceUID: PUT(CFStringRef, kDeviceUID);
    case kAudioDevicePropertyModelUID: PUT(CFStringRef, kModelUID);
    case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&sStateLock);
        UInt32 running = sIOClients > 0;
        pthread_mutex_unlock(&sStateLock);
        PUT(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, output ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
    case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
    case kAudioDevicePropertyLatency: PUT(UInt32, output ? atomic_load(&sLatencyFrames) : 0);
    case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kZeroPeriodFrames);
    case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange r = {kSampleRate, kSampleRate};
        PUT(AudioValueRange, r);
    }
    case kAudioDevicePropertyRelatedDevices: PUT(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        if (output) PUT(AudioObjectID, kObjectStream);
        PUT_NOTHING();
    case kAudioObjectPropertyControlList: PUT_NOTHING();
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (outSize) *outSize = 2 * sizeof(UInt32);
        if (data) {
            if (maxSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)data)[0] = 1;
            ((UInt32 *)data)[1] = 2;
        }
        return noErr;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info = {
            kPropertyLatencyFrames, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
            kAudioServerPlugInCustomPropertyDataTypeNone,
        };
        PUT(AudioServerPlugInCustomPropertyInfo, info);
    }
    case kPropertyLatencyFrames: {
        if (outSize) *outSize = sizeof(CFNumberRef);
        if (data) {
            if (maxSize < sizeof(CFNumberRef)) return kAudioHardwareBadPropertySizeError;
            UInt32 frames = atomic_load(&sLatencyFrames);
            *(CFNumberRef *)data = CFNumberCreate(NULL, kCFNumberSInt32Type, &frames); // caller releases
        }
        return noErr;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus streamProperty(const AudioObjectPropertyAddress *a, UInt32 maxSize, UInt32 *outSize, void *data) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: PUT_NOTHING();
    case kAudioStreamPropertyIsActive: PUT(UInt32, 1);
    case kAudioStreamPropertyDirection: PUT(UInt32, 0); // 0 = output
    case kAudioStreamPropertyTerminalType: PUT(UInt32, kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
    case kAudioStreamPropertyLatency: PUT(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, streamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription d = {streamFormat(), {kSampleRate, kSampleRate}};
        PUT(AudioStreamRangedDescription, d);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus objectProperty(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 qualifierSize,
                               const void *qualifier, UInt32 maxSize, UInt32 *outSize, void *data) {
    switch (object) {
    case kObjectPlugIn: return plugInProperty(a, qualifierSize, qualifier, maxSize, outSize, data);
    case kObjectDevice: return deviceProperty(a, maxSize, outSize, data);
    case kObjectStream: return streamProperty(a, maxSize, outSize, data);
    }
    return kAudioHardwareBadObjectError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a) {
    OSStatus status = objectProperty(object, a, 0, NULL, 0, NULL, NULL);
    return status != kAudioHardwareUnknownPropertyError && status != kAudioHardwareBadObjectError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    *outSettable = object == kObjectDevice && a->mSelector == kPropertyLatencyFrames;
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                    const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                                    UInt32 *outSize) {
    return objectProperty(object, a, qualifierSize, qualifier, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                                UInt32 maxSize, UInt32 *outSize, void *data) {
    return objectProperty(object, a, qualifierSize, qualifier, maxSize, outSize, data);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                                UInt32 size, const void *data) {
    if (object != kObjectDevice || a->mSelector != kPropertyLatencyFrames) return kAudioHardwareUnsupportedOperationError;
    if (size != sizeof(CFNumberRef) || !data) return kAudioHardwareBadPropertySizeError;
    CFNumberRef number = *(CFNumberRef *)data;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
    SInt32 frames = 0;
    CFNumberGetValue(number, kCFNumberSInt32Type, &frames);
    if (frames < 0) frames = 0;
    if ((UInt32)frames > kMaxLatencyFrames) frames = kMaxLatencyFrames;
    if (atomic_exchange(&sLatencyFrames, (UInt32)frames) == (UInt32)frames) return noErr;

    // The host must not be called back on this thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AudioObjectPropertyAddress changed[2] = {
            {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
            {kPropertyLatencyFrames, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        sHost->PropertiesChanged(sHost, kObjectDevice, 2, changed);
    });
    return noErr;
}

// MARK: IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&sStateLock);
    if (sIOClients++ == 0) {
        pthread_mutex_lock(&sClockLock);
        sAnchorHostTime = mach_absolute_time();
        sPeriodsElapsed = 0;
        pthread_mutex_unlock(&sClockLock);
    }
    pthread_mutex_unlock(&sStateLock);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&sStateLock);
    if (sIOClients > 0) sIOClients--;
    pthread_mutex_unlock(&sStateLock);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    pthread_mutex_lock(&sClockLock);
    Float64 ticksPerPeriod = sTicksPerFrame * kZeroPeriodFrames;
    UInt64 next = sAnchorHostTime + (UInt64)((sPeriodsElapsed + 1) * ticksPerPeriod);
    if (next <= mach_absolute_time()) sPeriodsElapsed++;
    *outSampleTime = sPeriodsElapsed * (Float64)kZeroPeriodFrames;
    *outHostTime = sAnchorHostTime + (UInt64)(sPeriodsElapsed * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&sClockLock);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                                  Boolean *outWillDo, Boolean *outInPlace) {
    *outWillDo = operation == kAudioServerPlugInIOOperationWriteMix;
    *outInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return noErr; }

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 client,
                              UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *info,
                              void *main, void *secondary) { return noErr; } // audio is discarded

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                               UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return noErr; }

// MARK: Plug-in boilerplate

static AudioServerPlugInDriverInterface sInterface;
static AudioServerPlugInDriverInterface *sInterfacePtr = &sInterface;

static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *out) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) return E_NOINTERFACE;
    atomic_fetch_add(&sRefCount, 1);
    *out = &sInterfacePtr;
    return S_OK;
}
static ULONG AddRef(void *driver) { return atomic_fetch_add(&sRefCount, 1) + 1; }
static ULONG Release(void *driver) { return atomic_fetch_sub(&sRefCount, 1) - 1; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    sHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sTicksPerFrame = (1e9 * timebase.denom / timebase.numer) / kSampleRate;
    os_log(OS_LOG_DEFAULT, "MultiAudioDevice loaded");
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) { return noErr; }
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) { return noErr; }

static AudioServerPlugInDriverInterface sInterface = {
    NULL, QueryInterface, AddRef, Release,
    Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformConfigChange, AbortConfigChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation,
    BeginIOOperation, DoIOOperation, EndIOOperation,
};

__attribute__((visibility("default")))
void *MultiAudioDevice_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return NULL;
    atomic_store(&sRefCount, 1);
    return &sInterfacePtr;
}
