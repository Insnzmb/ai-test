#!/usr/bin/env python3
import argparse
import socket
import time
from ctypes import windll


KEY_A = 1 << 0
KEY_B = 1 << 1
KEY_SELECT = 1 << 2
KEY_START = 1 << 3
KEY_LEFT = 1 << 4
KEY_RIGHT = 1 << 5
KEY_UP = 1 << 6
KEY_DOWN = 1 << 7

VK_UP = 0x26
VK_DOWN = 0x28
VK_LEFT = 0x25
VK_RIGHT = 0x27
VK_W = 0x57
VK_A = 0x41
VK_S = 0x53
VK_D = 0x44
VK_Z = 0x5A
VK_X = 0x58
VK_J = 0x4A
VK_K = 0x4B
VK_ENTER = 0x0D
VK_SHIFT = 0x10
VK_RSHIFT = 0xA1


def key_down(vk):
    return (windll.user32.GetAsyncKeyState(vk) & 0x8000) != 0


def read_mask():
    mask = 0

    if key_down(VK_UP) or key_down(VK_W):
        mask |= KEY_UP
    if key_down(VK_DOWN) or key_down(VK_S):
        mask |= KEY_DOWN
    if key_down(VK_LEFT) or key_down(VK_A):
        mask |= KEY_LEFT
    if key_down(VK_RIGHT) or key_down(VK_D):
        mask |= KEY_RIGHT
    if key_down(VK_Z) or key_down(VK_J):
        mask |= KEY_A
    if key_down(VK_X) or key_down(VK_K):
        mask |= KEY_B
    if key_down(VK_ENTER):
        mask |= KEY_START
    if key_down(VK_SHIFT) or key_down(VK_RSHIFT):
        mask |= KEY_SELECT

    return mask


class Endpoint:
    def __init__(self, host: str, port: int, name: str):
        self.host = host
        self.port = port
        self.name = name
        self.sock = None
        self.last_connect_try = 0.0

    def ensure_connected(self):
        if self.sock:
            return True
        now = time.time()
        if (now - self.last_connect_try) < 0.75:
            return False
        self.last_connect_try = now
        try:
            sock = socket.create_connection((self.host, self.port), timeout=0.6)
            sock.settimeout(0.6)
            self.sock = sock
            print(f"[bg-keys] connected {self.name} {self.host}:{self.port}", flush=True)
            return True
        except OSError:
            return False

    def send_mask(self, mask: int):
        if not self.ensure_connected():
            return
        packet = f"A|{mask}|2|kb\n".encode("utf-8")
        try:
            self.sock.sendall(packet)
        except OSError:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def main():
    parser = argparse.ArgumentParser(
        description="Background keyboard broadcaster for Gold/Silver mGBA bridges"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--gold-port", type=int, default=58891)
    parser.add_argument("--silver-port", type=int, default=58892)
    parser.add_argument("--target", choices=["silver", "gold", "both"], default="both")
    parser.add_argument("--hz", type=float, default=60.0)
    parser.add_argument("--keepalive", type=float, default=0.20)
    args = parser.parse_args()

    step = 1.0 / max(10.0, args.hz)
    keepalive_frames = max(1, int(args.keepalive / step))

    gold = Endpoint(args.host, args.gold_port, "gold")
    silver = Endpoint(args.host, args.silver_port, "silver")
    if args.target == "silver":
        endpoints = [silver]
    elif args.target == "gold":
        endpoints = [gold]
    else:
        endpoints = [gold, silver]

    print(
        "[bg-keys] global controls: arrows/WASD, Z/J=A, X/K=B, Enter=Start, Shift=Select",
        flush=True,
    )
    print(
        f"[bg-keys] target={args.target} gold:{args.gold_port} silver:{args.silver_port} at {args.hz:.1f}Hz",
        flush=True,
    )

    last_mask = -1
    frames_since_send = 0

    try:
        while True:
            mask = read_mask()
            should_send = False
            if mask != last_mask:
                should_send = True
                last_mask = mask
            elif frames_since_send >= keepalive_frames:
                should_send = True

            if should_send:
                for endpoint in endpoints:
                    endpoint.send_mask(mask)
                frames_since_send = 0
            else:
                frames_since_send += 1

            time.sleep(step)
    except KeyboardInterrupt:
        pass
    finally:
        for endpoint in endpoints:
            endpoint.close()


if __name__ == "__main__":
    main()
