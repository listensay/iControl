/*
 * Private HID ABI declarations based on Apple's IOKitSPI.h.
 * Copyright (C) 2015 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#ifndef ICONTROL_FPS_HID_BRIDGE_H
#define ICONTROL_FPS_HID_BRIDGE_H
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdint.h>

typedef void *FPSHIDEventRef;
typedef void *FPSHIDClientRef;
typedef FPSHIDEventRef (*FPSCreateHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, boolean_t, boolean_t, uint32_t);
typedef FPSHIDEventRef (*FPSCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, boolean_t, boolean_t, uint32_t);
typedef FPSHIDClientRef (*FPSCreateClient)(CFAllocatorRef);
typedef void (*FPSSetInteger)(FPSHIDEventRef, uint32_t, CFIndex);
typedef void (*FPSSetFloat)(FPSHIDEventRef, uint32_t, double);
typedef void (*FPSAppendEvent)(FPSHIDEventRef, FPSHIDEventRef, uint32_t);
typedef void (*FPSSetSender)(FPSHIDEventRef, uint64_t);
typedef void (*FPSDispatchEvent)(FPSHIDClientRef, FPSHIDEventRef);

enum { FPS_RANGE = 1, FPS_TOUCH = 2, FPS_POSITION = 4, FPS_IDENTITY = 32, FPS_ATTRIBUTE = 64, FPS_CANCEL = 128,
       FPS_BUILT_IN = 4, FPS_MAJOR_RADIUS = (11 << 16) + 20,
       FPS_MINOR_RADIUS = (11 << 16) + 21, FPS_DISPLAY_INTEGRATED = (11 << 16) + 25 };
#endif
