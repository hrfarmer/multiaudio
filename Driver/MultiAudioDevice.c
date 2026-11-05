// MultiAudio virtual output device: a Core Audio AudioServerPlugIn loaded by coreaudiod.
//
// It exists to tell video players how late audio will be. Apps play to this device, and the
// device reports MultiAudio's delay as its latency, so players hold back video to match.
// Its own output is discarded: MultiAudio's process tap captures what apps play.
//
// MultiAudio sets the latency through a custom property (kPropertyLatencyFrames). The device
// also has volume and mute controls so the volume keys work; they don't change anything here,
// MultiAudio reads them and applies them as a master volume on its real outputs.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectDevice = 2,
    kObjectStream = 3,
    kObjectVolume = 4,
    kObjectMute = 5,
};

#define kDeviceUID CFSTR("MultiAudioDevice_UID")
#define kModelUID CFSTR("MultiAudioDevice_ModelUID")
static const Float64 kSampleRate = 48000;
static const UInt32 kChannels = 2;
static const UInt32 kZeroPeriodFrames = 16384; // how often GetZeroTimeStamp's anchor advances
static const UInt32 kMaxLatencyFrames = 480000; // 10 s
static const AudioObjectPropertySelector kPropertyLatencyFrames = 'mlat';
static const Float32 kMinDecibels = -96;
#define kStorageVolume CFSTR("volume")
#define kStorageMuted CFSTR("muted")

static AudioServerPlugInHostRef sHost;
static pthread_mutex_t sStateLock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint sRefCount;
static atomic_uint sLatencyFrames;
static UInt32 sIOClients; // guarded by sStateLock, as are the next two
static Float32 sVolume = 1;
static UInt32 sMuted;
static Float64 sTicksPerFrame;
static UInt64 sAnchorHostTime; // set once: the clock runs from load, through every start and stop

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
#define PUT_LIST(T, ...) do { \
        const T list[] = {__VA_ARGS__}; \
        if (outSize) *outSize = sizeof(list); \
        if (data) { if (maxSize < sizeof(list)) return kAudioHardwareBadPropertySizeError; memcpy(data, list, sizeof(list)); } \
        return noErr; \
    } while (0)

// The app uses the scalar like its own sliders (gain = scalar^2), hence 40 rather than 20.
static Float32 scalarToDecibels(Float32 scalar) {
    if (!(scalar > 0)) return kMinDecibels;
    return fmaxf(kMinDecibels, fminf(0, 40 * log10f(scalar)));
}
static Float32 decibelsToScalar(Float32 db) {
    if (!(db > kMinDecibels)) return 0;
    return powf(10, fminf(0, db) / 40);
}

static Float32 lockedRead(const Float32 *value) {
    pthread_mutex_lock(&sStateLock);
    Float32 v = *value;
    pthread_mutex_unlock(&sStateLock);
    return v;
}

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
        if (a->mScope == kAudioObjectPropertyScopeInput) PUT_NOTHING();
        PUT_LIST(AudioObjectID, kObjectStream, kObjectVolume, kObjectMute);
    case kAudioDevicePropertyStreams:
        if (output) PUT(AudioObjectID, kObjectStream);
        PUT_NOTHING();
    case kAudioObjectPropertyControlList: PUT_LIST(AudioObjectID, kObjectVolume, kObjectMute);
    case kAudioDevicePropertyPreferredChannelsForStereo: PUT_LIST(UInt32, 1, 2);
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

static OSStatus volumeProperty(const AudioObjectPropertyAddress *a, UInt32 maxSize, UInt32 *outSize, void *data) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioLevelControlClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioVolumeControlClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: PUT_NOTHING();
    case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioLevelControlPropertyScalarValue: PUT(Float32, lockedRead(&sVolume));
    case kAudioLevelControlPropertyDecibelValue: PUT(Float32, scalarToDecibels(lockedRead(&sVolume)));
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange r = {kMinDecibels, 0};
        PUT(AudioValueRange, r);
    }
    // These two convert the value the caller passes in `data`, in place.
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        PUT(Float32, scalarToDecibels(data && maxSize >= sizeof(Float32) ? *(Float32 *)data : 0));
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        PUT(Float32, decibelsToScalar(data && maxSize >= sizeof(Float32) ? *(Float32 *)data : 0));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus muteProperty(const AudioObjectPropertyAddress *a, UInt32 maxSize, UInt32 *outSize, void *data) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: PUT_NOTHING();
    case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioBooleanControlPropertyValue: {
        pthread_mutex_lock(&sStateLock);
        UInt32 muted = sMuted;
        pthread_mutex_unlock(&sStateLock);
        PUT(UInt32, muted);
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
    case kObjectVolume: return volumeProperty(a, maxSize, outSize, data);
    case kObjectMute: return muteProperty(a, maxSize, outSize, data);
    }
    return kAudioHardwareBadObjectError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a) {
    OSStatus status = objectProperty(object, a, 0, NULL, 0, NULL, NULL);
    return status != kAudioHardwareUnknownPropertyError && status != kAudioHardwareBadObjectError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    *outSettable = (object == kObjectDevice && a->mSelector == kPropertyLatencyFrames)
        || (object == kObjectVolume && (a->mSelector == kAudioLevelControlPropertyScalarValue
                                        || a->mSelector == kAudioLevelControlPropertyDecibelValue))
        || (object == kObjectMute && a->mSelector == kAudioBooleanControlPropertyValue);
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

// The host must not be called back on the thread that's setting a property.
static void notifyChanged(AudioObjectID object, AudioObjectPropertySelector first, AudioObjectPropertySelector second,
                          AudioObjectPropertyScope firstScope) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AudioObjectPropertyAddress changed[2] = {
            {first, firstScope, kAudioObjectPropertyElementMain},
            {second, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        sHost->PropertiesChanged(sHost, object, second ? 2 : 1, changed);
    });
}

static void store(CFStringRef key, CFNumberType type, const void *value) {
    CFNumberRef number = CFNumberCreate(NULL, type, value);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sHost->WriteToStorage(sHost, key, number);
        CFRelease(number);
    });
}

static Boolean loadNumber(CFStringRef key, CFNumberType type, void *value) {
    CFPropertyListRef stored = NULL;
    if (sHost->CopyFromStorage(sHost, key, &stored) != noErr || !stored) return false;
    Boolean ok = CFGetTypeID(stored) == CFNumberGetTypeID() && CFNumberGetValue(stored, type, value);
    CFRelease(stored);
    return ok;
}

static OSStatus setLatency(UInt32 size, const void *data) {
    if (size != sizeof(CFNumberRef) || !data) return kAudioHardwareBadPropertySizeError;
    CFNumberRef number = *(CFNumberRef *)data;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
    SInt32 frames = 0;
    CFNumberGetValue(number, kCFNumberSInt32Type, &frames);
    if (frames < 0) frames = 0;
    if ((UInt32)frames > kMaxLatencyFrames) frames = kMaxLatencyFrames;
    if (atomic_exchange(&sLatencyFrames, (UInt32)frames) != (UInt32)frames) {
        notifyChanged(kObjectDevice, kAudioDevicePropertyLatency, kPropertyLatencyFrames, kAudioObjectPropertyScopeOutput);
    }
    return noErr;
}

static OSStatus setVolume(Float32 scalar) {
    if (isnan(scalar)) return kAudioHardwareIllegalOperationError;
    scalar = fmaxf(0, fminf(1, scalar));
    pthread_mutex_lock(&sStateLock);
    Boolean changed = scalar != sVolume;
    sVolume = scalar;
    pthread_mutex_unlock(&sStateLock);
    if (changed) {
        notifyChanged(kObjectVolume, kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue,
                      kAudioObjectPropertyScopeGlobal);
        store(kStorageVolume, kCFNumberFloat32Type, &scalar);
    }
    return noErr;
}

static OSStatus setMuted(UInt32 muted) {
    muted = muted != 0;
    pthread_mutex_lock(&sStateLock);
    Boolean changed = muted != sMuted;
    sMuted = muted;
    pthread_mutex_unlock(&sStateLock);
    if (changed) {
        notifyChanged(kObjectMute, kAudioBooleanControlPropertyValue, 0, kAudioObjectPropertyScopeGlobal);
        store(kStorageMuted, kCFNumberSInt32Type, &muted);
    }
    return noErr;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                                UInt32 size, const void *data) {
    if (object == kObjectDevice && a->mSelector == kPropertyLatencyFrames) return setLatency(size, data);

    Boolean scalar = object == kObjectVolume && a->mSelector == kAudioLevelControlPropertyScalarValue;
    Boolean decibels = object == kObjectVolume && a->mSelector == kAudioLevelControlPropertyDecibelValue;
    Boolean mute = object == kObjectMute && a->mSelector == kAudioBooleanControlPropertyValue;
    if (!scalar && !decibels && !mute) return kAudioHardwareUnsupportedOperationError;
    if (size != sizeof(Float32) || !data) return kAudioHardwareBadPropertySizeError; // UInt32 is the same size
    if (mute) return setMuted(*(const UInt32 *)data);
    Float32 value = *(const Float32 *)data;
    return setVolume(decibels ? decibelsToScalar(value) : value);
}

// MARK: IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&sStateLock);
    sIOClients++;
    pthread_mutex_unlock(&sStateLock);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&sStateLock);
    if (sIOClients > 0) sIOClients--;
    pthread_mutex_unlock(&sStateLock);
    return noErr;
}

// Worked out from the time rather than counted, so it can't fall behind if the host calls late,
// and it never restarts, which the host would otherwise see as time jumping within one seed.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    Float64 ticksPerPeriod = sTicksPerFrame * kZeroPeriodFrames;
    UInt64 periods = (UInt64)((mach_absolute_time() - sAnchorHostTime) / ticksPerPeriod);
    *outSampleTime = periods * (Float64)kZeroPeriodFrames;
    *outHostTime = sAnchorHostTime + (UInt64)(periods * ticksPerPeriod);
    *outSeed = 1;
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
    sAnchorHostTime = mach_absolute_time();
    Float32 volume;
    if (loadNumber(kStorageVolume, kCFNumberFloat32Type, &volume) && volume >= 0 && volume <= 1) sVolume = volume;
    UInt32 muted;
    if (loadNumber(kStorageMuted, kCFNumberSInt32Type, &muted)) sMuted = muted != 0;
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
