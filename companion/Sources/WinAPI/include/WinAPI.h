// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Exposes Win32 common controls, WinHTTP, and resource APIs not re-exported by Swift's
// WinSDK module. Empty on non-Windows platforms.
#pragma once
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <winhttp.h>
#endif
