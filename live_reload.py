#!/usr/bin/env python3
import argparse
import socket
import sys


def main():
    parser = argparse.ArgumentParser(description="Send control commands to mGBA live-loader")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cmd", default="reload", choices=["reload", "status"])
    parser.add_argument("--timeout", type=float, default=1.5)
    args = parser.parse_args()

    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    except OSError as err:
        print(f"[live-reload] connect failed: {err}", flush=True)
        return 2

    with sock:
        sock.settimeout(args.timeout)
        try:
            sock.sendall((args.cmd + "\n").encode("utf-8"))
            data = sock.recv(512).decode("utf-8", errors="replace").strip()
            if data:
                print(f"[live-reload] {data}", flush=True)
            else:
                print("[live-reload] no response", flush=True)
            if data.startswith("R|OK|"):
                return 0
            return 1
        except OSError as err:
            print(f"[live-reload] command failed: {err}", flush=True)
            return 1


if __name__ == "__main__":
    sys.exit(main())

