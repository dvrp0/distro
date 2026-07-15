#!/usr/bin/env python3
import argparse
import json
import os
import socket
import struct
import sys
import time


def find_discord_ipc():
    bases = []
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        bases.append(xdg)
    bases.append("/tmp")
    uid = os.getuid()
    bases.append("/run/user/%d" % uid)
    subs = [
        "",
        "app/com.discordapp.Discord/",
        "app/com.discordapp.DiscordCanary/",
        "app/com.discordapp.DiscordPTB/",
        "app/com.discord.Discord/",
        "snap.discord/",
        "snap.discord-canary/",
        "snap.discord-ptb/",
        ".flatpak/com.discordapp.Discord/xdg-run/",
        ".flatpak/com.discordapp.DiscordCanary/xdg-run/",
        ".flatpak/com.discordapp.DiscordPTB/xdg-run/",
        "app/com.valvesoftware.Steam/",
    ]
    seen = set()
    for base in bases:
        if not base or base in seen:
            continue
        seen.add(base)
        for i in range(10):
            for sub in subs:
                path = os.path.join(base, sub, "discord-ipc-%d" % i)
                if os.path.exists(path):
                    return path
    return None


def pack_msg(opcode, payload):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    return struct.pack("<II", opcode, len(payload)) + payload


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def recv_msg(sock):
    hdr = recv_exact(sock, 8)
    if not hdr:
        return None, None
    opcode, length = struct.unpack("<II", hdr)
    if length < 0 or length > 1048576:
        return None, None
    data = recv_exact(sock, length)
    if data is None:
        return None, None
    return opcode, data.decode("utf-8", errors="replace")


class Bridge:
    def __init__(self, ipc_dir):
        self.ipc_dir = ipc_dir
        self.sock = None
        self.discord_path = None

    def connect_discord(self):
        if self.sock:
            return True
        path = find_discord_ipc()
        if not path:
            return False
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        try:
            sock.connect(path)
        except OSError:
            sock.close()
            return False
        self.sock = sock
        self.discord_path = path
        return True

    def close_discord(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def exchange(self, opcode, data, expect_reply=True):
        if not self.connect_discord():
            return False, None, "discord socket unavailable"
        try:
            self.sock.sendall(pack_msg(opcode, data))
            if not expect_reply:
                return True, None, None
            op, payload = recv_msg(self.sock)
            if op is None:
                self.close_discord()
                return False, None, "discord closed"
            return True, op, payload
        except OSError as exc:
            self.close_discord()
            return False, None, str(exc)

    def write_reply(self, req_id, ok, op=None, data=None, error=None):
        payload = {"id": req_id, "ok": bool(ok)}
        if op is not None:
            payload["op"] = op
        if error is not None:
            payload["error"] = error
        path = os.path.join(self.ipc_dir, "rep-%s.json" % req_id)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)

        data_path = os.path.join(self.ipc_dir, "rep-%s.data" % req_id)
        if data is not None:
            data_tmp = data_path + ".tmp"
            with open(data_tmp, "w", encoding="utf-8") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(data_tmp, data_path)
        else:
            try:
                os.remove(data_path)
            except OSError:
                pass

    def handle_request(self, path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                req = json.load(handle)
        except (OSError, ValueError, json.JSONDecodeError):
            try:
                os.remove(path)
            except OSError:
                pass
            return

        req_id = str(req.get("id", ""))
        opcode = int(req.get("op", 1))
        data = req.get("data", "{}")
        wait = bool(req.get("wait", opcode == 0))

        if not req_id:
            try:
                os.remove(path)
            except OSError:
                pass
            return

        try:
            os.remove(path)
        except OSError:
            pass

        if opcode == 2:
            ok, op, payload = self.exchange(opcode, data, expect_reply=False)
            self.close_discord()
            self.write_reply(req_id, ok, error=None if ok else "close failed")
            return

        ok, op, payload = self.exchange(opcode, data, expect_reply=wait)
        if ok:
            self.write_reply(req_id, True, op=op, data=payload)
        else:
            self.write_reply(req_id, False, error=payload or "exchange failed")

    def run(self):
        os.makedirs(self.ipc_dir, exist_ok=True)
        ready = os.path.join(self.ipc_dir, "bridge.ready")
        with open(ready, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())

        try:
            while True:
                try:
                    names = sorted(os.listdir(self.ipc_dir))
                except OSError:
                    time.sleep(0.05)
                    continue

                for name in names:
                    if name.startswith("req-") and name.endswith(".json"):
                        self.handle_request(os.path.join(self.ipc_dir, name))

                time.sleep(0.02)
        finally:
            try:
                os.remove(ready)
            except OSError:
                pass
            self.close_discord()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    args = parser.parse_args()
    bridge = Bridge(args.dir)
    print("Distro bridge watching %s" % args.dir, flush=True)
    try:
        bridge.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
