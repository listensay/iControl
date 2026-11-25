# Third-party software

The original Mac application and transport code are under the MIT license.
The following independent packages and libraries keep their respective licenses.

## TrollVNC

- Project: https://github.com/owngoal-dev/TrollVNC
- Release: https://github.com/owngoal-dev/TrollVNC/releases/tag/v3.2-272
- Release source commit: `17c37b2ff1797b158604d16111a682e84390503d`
- License: GPL-2.0, provided in `Resources/ServerPackages/TrollVNC-LICENSE.txt` inside the app resource bundle.
- The official, unmodified rootful and rootless `.deb` files are bundled as separate iPad installation packages. No TrollVNC binary is linked into the Mac executable.
- A source archive from that release, including the upstream build files and vendored files, is provided in the application resource bundle under `Resources/ThirdPartySources/`.

Package SHA256:

```text
eff873a15d6b5a2afb287111f04a8a89532cb4bf7acbf63b5e3160c8a27753df  com.82flex.trollvnc_3.2-272_iphoneos-arm64.deb·
6e19c0e3df87ba1e83e6ebf2208c3480ce7defb858c2835ac50cef611d385028  com.82flex.trollvnc_3.2-272_iphoneos-arm.deb
```·

## noVNC

- Project: https://github.com/novnc/noVNC
- License: MPL-2.0 for the JavaScript core; individual copyright notices are preserved in each file.
- The pinned core and vendor snapshot is taken without modification from the TrollVNC release source commit above, at `layout/usr/share/trollvnc/webclients/novnc`.
- The actual JavaScript source is distributed in the application resource bundle at `Resources/Viewer/novnc` and in this source tree. iControl's integration wrapper is separate at `Resources/Viewer/viewer.js`.
- The MPL-2.0 and BSD texts, noVNC authors list, and upstream license summary are in `Resources/Licenses/`.
- The incorporated DES implementation's copyright/license notices are preserved in `core/crypto/des.js`.

## iControl FPS daemon

- Independent iPad executable: `Device/FPSDaemon`, version 1.4.0, contact protocol 1 with optional visual cursor messages, greeting revision 14.
- License: GPL-2.0-only. The complete corresponding source, embedded metadata and entitlement file are distributed in `Resources/ThirdPartySources/iControl-FPSDaemon-1.4.0-source.tar.gz`; the full license text is in `Resources/FPSDaemon/COPYING`.
- HID event dispatch conventions follow TrollVNC's `STHIDEventGenerator.mm` from the source release listed above. The original TrollVNC source archive is also included.
- Private HID ABI declarations are based on Apple IOKitSPI.h, Copyright (C) 2015 Apple Inc., under its two-clause BSD license. The complete notice and disclaimer are preserved in `Device/FPSDaemon/HIDBridge.h` and the bundled `Resources/FPSDaemon/HIDBridge.h`.
- The daemon is installed as a separate root launch job and is not linked into the Mac executable or the TrollVNC binary. Its build script and signed arm64 binary manifest are included.

## TrollSpeed window-hosting reference

- Project: https://github.com/Lessica/TrollSpeed
- License: MIT, Copyright (c) 2023 Lessica.
- The UIKit plugin initialization and accessibility window-hosting API sequence in `Device/FPSDaemon/DeviceCursor.m` follow that project's HUD implementation. No input fetching code is incorporated. The passive cursor renderer runs as an isolated child of the FPS daemon.
- The full MIT notice is preserved in `Device/FPSDaemon/CursorHosting-NOTICE.txt` and the bundled `Resources/FPSDaemon/CursorHosting-NOTICE.txt`.

## QtScrcpy steering-wheel reference

- Project: https://github.com/barry-ran/QtScrcpy
- Reference implementation: https://github.com/barry-ran/QtScrcpyCore/blob/9e388b8aa48e4e1c2cfdef408ef00c4c6b45c921/src/device/controller/inputconvert/inputconvertgame.cpp
- Upstream license: Apache-2.0.
- iControl independently implements a Swift wheel inspired by QtScrcpy's continuous-touch lifecycle and straight-line travel. No QtScrcpy source or binary is bundled. iControl constrains diagonal targets to the displayed circular radius and immediately clears a released axis to avoid residual sideways travel. It uses deterministic elapsed time rather than randomized points or timer delays, and opposing keys retain iControl’s most-recent-key priority.

## Build tools

- The optional iPad build toolchain is downloaded into `work/toolchain/` and excluded from the distributed source archive.
- Theos SDKs: https://github.com/theos/sdks, pinned commit `0222fd5413cf4b9af096f37b4621afa2688572f7`, iPhoneOS16.5.sdk. Consult that project's license and the SDK terms when supplying an alternative SDK.
- Procursus ldid: https://github.com/ProcursusTeam/ldid, release `v2.1.5-procursus8`, macOS arm64; expected SHA256 `99b8c3052c188184e259b9c512f8ceb7c40ca89e44c99bb96b38c4bd635ff4df`. This build dependency is not bundled into the application.

## Pako

- Project: https://github.com/nodeca/pako
- License: MIT, including the notices for zlib-derived code.
- Source and its license are in the application resource bundle at `Resources/Viewer/novnc/vendor/pako/`.

## macOS components

SwiftUI, AppKit, WebKit, IOKit, Security, and the SSH executable are supplied by macOS. They are not redistributed here.
