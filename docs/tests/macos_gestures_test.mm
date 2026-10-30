// Construction and lifecycle tests. CGEventPost is replaced with a recorder:
// running this binary does not inject events or switch the local user's Spaces.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <cassert>
#include <cstdio>
#include <limits>
#include <vector>

struct RecordedGesture { uint32_t type; int64_t axis; int64_t phase; double progress; };
static std::vector<RecordedGesture> recorded;
static void RecordGesture(CGEventTapLocation, CGEventRef event) {
    recorded.push_back({static_cast<uint32_t>(CGEventGetType(event)),
        CGEventGetIntegerValueField(event, static_cast<CGEventField>(123)),
        CGEventGetIntegerValueField(event, static_cast<CGEventField>(132)),
        CGEventGetDoubleValueField(event, static_cast<CGEventField>(124))});
}
#define CGEventPost RecordGesture
#include "../../engine/rustdesk/src/platform/macos_gestures.mm"
#undef CGEventPost

int main() {
    @autoreleasepool {
        for (uint32_t axis : {1, 2, 3}) {
            for (uint32_t phase : {1, 2, 4, 8}) {
                CGEventRef event = RDGestureCreate(axis, phase, -0.45, 12.5, true);
                assert(event && CGEventGetType(event) == static_cast<CGEventType>(30));
                assert(CGEventGetIntegerValueField(event, static_cast<CGEventField>(110)) == 23);
                assert(CGEventGetIntegerValueField(event, static_cast<CGEventField>(123)) == axis);
                assert(CGEventGetIntegerValueField(event, static_cast<CGEventField>(132)) == phase);
                assert(std::abs(CGEventGetDoubleValueField(event, static_cast<CGEventField>(124)) + 0.45) < 1e-6);
                assert(CGEventGetDoubleValueField(event, static_cast<CGEventField>(129)) == 12.5);
                assert(CGEventGetIntegerValueField(event, static_cast<CGEventField>(136)) == 1);
                CFRelease(event);
            }
        }
        assert(!RDGestureCreate(0, 1, 0, 0, false));
        assert(!RDGestureCreate(4, 1, 0, 0, false));
        assert(!RDGestureCreate(1, 3, 0, 0, false));
        assert(!RDGestureCreate(1, 1, 17, 0, false));
        assert(!RDGestureCreate(1, 1, 0, 10001, false));
        assert(!RDGestureCreate(1, 1, std::numeric_limits<double>::quiet_NaN(), 0, false));
        assert(!RDGestureCreate(1, 1, 0, std::numeric_limits<double>::infinity(), false));

        if (RDGesturesSupported()) {
            RDPostRemoteGesture(10, 1, 2, .2, 0, false); // no begin
            assert(recorded.empty());
            RDPostRemoteGesture(10, 1, 1, .1, 0, false);
            RDPostRemoteGesture(10, 1, 2, .5, 0, false);
            assert(recorded.size() == 4 && recorded[2].progress == .5);
            RDPostRemoteGesture(20, 1, 4, .6, 0, false); // wrong owner
            RDPostRemoteGesture(10, 2, 2, .6, 0, false); // wrong axis
            assert(recorded.size() == 4);
            RDPostRemoteGesture(20, 2, 1, .1, 0, false); // cancel old, start new
            assert(recorded.size() == 8 && recorded[4].phase == 8 && recorded[6].phase == 1);
            RDPostRemoteGesture(10, 1, 4, .6, 0, false); // old owner cannot finish new
            assert(recorded.size() == 8);
            RDPostRemoteGesture(20, 2, 4, 1.5, 8, false);
            assert(recorded.size() == 10 && rdGestureAxis == 0);
            RDPostRemoteGesture(20, 2, 2, .6, 0, false); // no updates after end
            assert(recorded.size() == 10);
            RDPostRemoteGesture(10, 1, 1, .1, 0, false);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.7]];
            assert(recorded.size() == 14 && recorded[12].phase == 8 && rdGestureAxis == 0);
        }
        std::puts("PASS: native gesture fields, invalid packets, ownership, phases and timeout cancellation");
    }
}
