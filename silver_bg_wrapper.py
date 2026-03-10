#!/usr/bin/env python3
import argparse
import os
import subprocess
import time
from ctypes import POINTER, WINFUNCTYPE, byref, c_bool, c_int, c_uint, c_void_p, create_unicode_buffer, windll
from ctypes import wintypes


SW_SHOWNOACTIVATE = 4
SW_MINIMIZE = 6

GW_OWNER = 4

SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040

HWND_BOTTOM = c_void_p(1)


EnumWindowsProc = WINFUNCTYPE(c_bool, wintypes.HWND, wintypes.LPARAM)
user32 = windll.user32

user32.EnumWindows.argtypes = [EnumWindowsProc, wintypes.LPARAM]
user32.EnumWindows.restype = c_bool
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = c_bool
user32.GetWindow.argtypes = [wintypes.HWND, c_uint]
user32.GetWindow.restype = wintypes.HWND
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.restype = c_int
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, c_int]
user32.GetWindowTextW.restype = c_int
user32.SetWindowPos.argtypes = [
    wintypes.HWND,
    wintypes.HWND,
    c_int,
    c_int,
    c_int,
    c_int,
    c_uint,
]
user32.SetWindowPos.restype = c_bool
user32.ShowWindow.argtypes = [wintypes.HWND, c_int]
user32.ShowWindow.restype = c_bool


def _top_window_for_pid(pid: int):
    result = {"hwnd": None}

    def cb(hwnd, lparam):
        proc_id = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, byref(proc_id))
        if proc_id.value != pid:
            return True
        if not user32.IsWindowVisible(hwnd):
            return True
        owner = user32.GetWindow(hwnd, GW_OWNER)
        if owner:
            return True
        result["hwnd"] = hwnd
        return False

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return result["hwnd"]


def _window_title(hwnd):
    length = user32.GetWindowTextLengthW(hwnd)
    if length <= 0:
        return ""
    buf = create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def _top_window_for_title(needle: str):
    result = {"hwnd": None}
    needle_l = (needle or "").strip().lower()
    if not needle_l:
        return None

    def cb(hwnd, lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        owner = user32.GetWindow(hwnd, GW_OWNER)
        if owner:
            return True
        title = _window_title(hwnd).lower()
        if needle_l in title:
            result["hwnd"] = hwnd
            return False
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return result["hwnd"]


def wait_for_window(pid: int, timeout: float):
    deadline = time.time() + timeout
    hwnd = None
    while time.time() < deadline:
        hwnd = _top_window_for_pid(pid)
        if hwnd:
            return hwnd
        time.sleep(0.15)
    return hwnd


def wait_for_title(needle: str, timeout: float):
    deadline = time.time() + timeout
    hwnd = None
    while time.time() < deadline:
        hwnd = _top_window_for_title(needle)
        if hwnd:
            return hwnd
        time.sleep(0.15)
    return hwnd


def park_window(hwnd, x: int, y: int, width: int, height: int):
    user32.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    user32.SetWindowPos(
        hwnd,
        HWND_BOTTOM,
        x,
        y,
        width,
        height,
        SWP_NOACTIVATE | SWP_SHOWWINDOW,
    )


def minimize_window(hwnd):
    user32.ShowWindow(hwnd, SW_MINIMIZE)


def main():
    parser = argparse.ArgumentParser(
        description="Launch Pokemon Silver mGBA and keep it background-friendly for AI control."
    )
    parser.add_argument("--mgba", help="Path to mGBA.exe")
    parser.add_argument("--script", help="Path to Lua script")
    parser.add_argument("--rom", help="Path to Silver ROM")
    parser.add_argument("--mode", choices=["fg", "bg", "min", "park"], default="bg")
    parser.add_argument("--attach-pid", type=int, default=0, help="Existing mGBA PID to park")
    parser.add_argument(
        "--title-contains",
        default="Pokemon - Silver",
        help="Title fragment to find an existing Silver window when using --mode park",
    )
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--hold-seconds", type=float, default=10.0)
    parser.add_argument("--x", type=int, default=32000)
    parser.add_argument("--y", type=int, default=32000)
    parser.add_argument("--width", type=int, default=480)
    parser.add_argument("--height", type=int, default=432)
    args = parser.parse_args()

    proc = None
    hwnd = None

    if args.mode == "park":
        if args.attach_pid > 0:
            hwnd = wait_for_window(args.attach_pid, args.timeout)
        if not hwnd:
            hwnd = wait_for_title(args.title_contains, args.timeout)
        if not hwnd:
            print("[silver-wrap] warning: no matching Silver window found to park", flush=True)
            return 0
        park_window(hwnd, args.x, args.y, args.width, args.height)
    else:
        if not args.mgba or not args.script or not args.rom:
            parser.error("--mgba, --script, and --rom are required unless --mode park is used")
        cmd = [args.mgba, "--script", args.script, args.rom]
        cwd = os.path.dirname(args.mgba) or None
        proc = subprocess.Popen(cmd, cwd=cwd)
        print(f"[silver-wrap] launched mGBA pid={proc.pid} mode={args.mode}", flush=True)

        if args.mode == "fg":
            return 0

        hwnd = wait_for_window(proc.pid, args.timeout)
        if not hwnd:
            print("[silver-wrap] warning: no top-level mGBA window found in time", flush=True)
            return 0

        if args.mode == "min":
            minimize_window(hwnd)
            return 0

        park_window(hwnd, args.x, args.y, args.width, args.height)

    if args.hold_seconds <= 0:
        return 0

    deadline = time.time() + args.hold_seconds
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            break
        hwnd_now = None
        if proc is not None:
            hwnd_now = _top_window_for_pid(proc.pid)
        if hwnd_now is None and args.mode == "park":
            if args.attach_pid > 0:
                hwnd_now = _top_window_for_pid(args.attach_pid)
            if hwnd_now is None:
                hwnd_now = _top_window_for_title(args.title_contains)
        if hwnd_now:
            park_window(hwnd_now, args.x, args.y, args.width, args.height)
        time.sleep(0.30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
