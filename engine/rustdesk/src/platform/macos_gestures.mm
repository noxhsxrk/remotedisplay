// remotedisplay: Dock gesture construction for macOS 14–26.
// Private field meanings are documented in docs/tests/macos-gestures.md.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <initializer_list>

static bool RDGestureValid(uint32_t axis, uint32_t phase, double progress, double velocity) {
    return axis >= 1 && axis <= 3 && (phase == 1 || phase == 2 || phase == 4 || phase == 8)
        && std::isfinite(progress) && std::abs(progress) <= 16
        && std::isfinite(velocity) && std::abs(velocity) <= 10000;
}

static CGEventRef RDGestureCreate(uint32_t axis, uint32_t phase, double progress,
                                  double velocity, bool inverted) {
    if (!RDGestureValid(axis, phase, progress, velocity)) return nullptr;
    CGEventRef event = CGEventCreate(nullptr);
    if (!event) return nullptr;
    CGEventSetType(event, static_cast<CGEventType>(30));
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0x524447455354);
    CGEventSetIntegerValueField(event, static_cast<CGEventField>(110), 23);
    for (auto field : {123, 165}) CGEventSetDoubleValueField(event, static_cast<CGEventField>(field), axis);
    // The redundant axis fields contain the bit pattern of a Float32 subnormal.
    float axisValue;
    std::memcpy(&axisValue, &axis, sizeof(axis));
    for (auto field : {119, 139}) CGEventSetDoubleValueField(event, static_cast<CGEventField>(field), axisValue);
    for (auto field : {132, 134}) CGEventSetIntegerValueField(event, static_cast<CGEventField>(field), phase);
    CGEventSetDoubleValueField(event, static_cast<CGEventField>(124), progress);
    float offset = static_cast<float>(progress);
    uint32_t offsetBits;
    std::memcpy(&offsetBits, &offset, sizeof(offset));
    CGEventSetIntegerValueField(event, static_cast<CGEventField>(135), offsetBits);
    CGEventSetIntegerValueField(event, static_cast<CGEventField>(136), inverted);
    for (auto field : {129, 130}) CGEventSetDoubleValueField(event, static_cast<CGEventField>(field), velocity);
    CGEventSetIntegerValueField(event, static_cast<CGEventField>(41), 33231);
    return event;
}

extern "C" bool RDGesturesSupported() {
    NSInteger version = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return version >= 14 && version <= 26;
}

static void RDGesturePost(uint32_t axis, uint32_t phase, double progress, double velocity, bool inverted) {
    CGEventRef event = RDGestureCreate(axis, phase, progress, velocity, inverted);
    CGEventRef marker = CGEventCreate(nullptr);
    if (event && marker) {
        CGEventSetType(marker, static_cast<CGEventType>(29));
        CGEventSetIntegerValueField(marker, kCGEventSourceUserData, 0x524447455354);
        CGEventSetIntegerValueField(marker, static_cast<CGEventField>(41), 33231);
        CGEventPost(kCGSessionEventTap, event);
        CGEventPost(kCGSessionEventTap, marker);
    }
    if (event) CFRelease(event);
    if (marker) CFRelease(marker);
}

// Main-thread state, shared by all connections. Only one Dock transition can
// own the host at a time. A watchdog cancels a sequence whose sender disappears.
static int32_t rdGestureOwner = 0;
static uint32_t rdGestureAxis = 0;
static double rdGestureProgress = 0;
static bool rdGestureInverted = false;
static uint64_t rdGestureGeneration = 0;

extern "C" void RDPostRemoteGesture(int32_t connection, uint32_t axis, uint32_t phase,
                                     double progress, double velocity, bool inverted) {
    if (!NSThread.isMainThread || !RDGesturesSupported()
        || !RDGestureValid(axis, phase, progress, velocity)) return;
    if (phase == 1) {
        if (rdGestureAxis) RDGesturePost(rdGestureAxis, 8, rdGestureProgress, 0, rdGestureInverted);
        rdGestureOwner = connection;
        rdGestureAxis = axis;
    } else if (!rdGestureAxis || connection != rdGestureOwner || axis != rdGestureAxis) {
        return;
    }
    rdGestureProgress = progress;
    rdGestureInverted = inverted;
    RDGesturePost(axis, phase, progress, velocity, inverted);
    uint64_t generation = ++rdGestureGeneration;
    if (phase == 4 || phase == 8) {
        rdGestureAxis = 0;
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (generation == rdGestureGeneration && rdGestureAxis) {
                RDGesturePost(rdGestureAxis, 8, rdGestureProgress, 0, rdGestureInverted);
                rdGestureAxis = 0;
                ++rdGestureGeneration;
            }
        });
    }
}
