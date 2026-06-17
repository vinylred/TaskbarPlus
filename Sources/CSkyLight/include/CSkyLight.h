#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <CoreFoundation/CoreFoundation.h>

/*
 * Private CoreGraphics / SkyLight ("CGS") symbols.
 *
 * These have no public headers. We declare the signatures we use here; they
 * resolve at link time against /System/Library/PrivateFrameworks/SkyLight.framework
 * (linked via the -framework SkyLight flag in Package.swift).
 *
 * App Store distribution is NOT a goal. These are read-only Space-query calls,
 * which are far more stable across macOS releases than the mutating space APIs.
 */

typedef int CGSConnectionID;

/* The main connection to the WindowServer. Cache the result. */
extern CGSConnectionID CGSMainConnectionID(void);

/*
 * Full per-display layout of managed spaces. Returns a CFArrayRef of CFDictionary,
 * one entry per display. Each display dict contains (keys are strings, may drift):
 *   "Display Identifier"  -> CFString (display UUID)
 *   "Current Space"       -> CFDictionary describing the active space, with
 *                              "ManagedSpaceID" / "id64" -> CFNumber (the space id)
 *   "Spaces"              -> CFArray of space dicts (same id keys)
 * Caller owns the returned array (CFRelease).
 */
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

/*
 * Current (active) space id for a given display UUID. Convenience alongside the
 * tree above; used as a cross-check.
 */
extern uint64_t CGSManagedDisplayGetCurrentSpace(CGSConnectionID cid, CFStringRef displayUUID);

/*
 * Given an array of window numbers (CFArray of CFNumber), return the set of space
 * ids those windows belong to. `selector` (a.k.a. mask) selects which space set to
 * consider; 0x7 = (current | other | all) is the robust choice — we filter the
 * result ourselves against the known current-space set.
 * Returns a CFArrayRef of CFNumber (space ids). Caller owns it (CFRelease).
 */
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int selector, CFArrayRef windowIDs) CF_RETURNS_RETAINED;

/*
 * Dock notification trigger, exported by HIServices (part of ApplicationServices,
 * already linked via AppKit) — no separate framework flag needed.
 *
 * Used to invoke App Exposé for the frontmost app:
 *   CoreDockSendNotification(CFSTR("com.apple.expose.front.awake"), 0);
 * Other notifications: "com.apple.expose.awake" (Mission Control),
 * "com.apple.showdesktop.awake" (Show Desktop).
 */
extern void CoreDockSendNotification(CFStringRef notification, int arg);

#endif /* CSKYLIGHT_H */
