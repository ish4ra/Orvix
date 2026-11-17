#!/usr/bin/env python3
"""Say whether this Mac offers hardware-accelerated OpenGL.

Prints "yes" or "no". The video output of media_kit (the MPV player) asks
macOS for an accelerated OpenGL 3.2 pixel format and cannot run without one.
Real Macs have it. Virtual Macs, such as hosted build machines, usually do
not, so an app that opens a video output stops there on them.
"""

from __future__ import annotations

import ctypes
import sys

# CGL pixel format attributes (OpenGL/CGLTypes.h).
K_CGL_PFA_OPENGL_PROFILE = 99
K_CGL_OGLP_VERSION_3_2_CORE = 0x3200
K_CGL_PFA_ACCELERATED = 73


def accelerated_opengl_available() -> bool:
    opengl = ctypes.CDLL("/System/Library/Frameworks/OpenGL.framework/OpenGL")
    attributes = (ctypes.c_int * 4)(
        K_CGL_PFA_OPENGL_PROFILE,
        K_CGL_OGLP_VERSION_3_2_CORE,
        K_CGL_PFA_ACCELERATED,
        0,
    )
    pixel_format = ctypes.c_void_p()
    count = ctypes.c_int(0)
    error = opengl.CGLChoosePixelFormat(
        attributes, ctypes.byref(pixel_format), ctypes.byref(count)
    )
    return error == 0 and bool(pixel_format.value)


if __name__ == "__main__":
    try:
        print("yes" if accelerated_opengl_available() else "no")
    except OSError as error:
        print(f"unknown ({error})")
        sys.exit(0)
