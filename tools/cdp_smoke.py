#!/usr/bin/env python3
"""Headless-Chrome driver for test_import_headless.R (standard library only).

Launches Chrome with the DevTools protocol, opens a page, and runs a list of
JavaScript steps in real time, polling a page-side state function between
steps. Prints one JSON object (the final state plus the step log) to stdout.

usage: cdp_smoke.py --chrome <binary> --url <page> --steps <steps.json>
steps.json: {"state": "<js expression returning an object>",
             "steps": [{"name": "...", "js": "<js, may return a Promise>",
                        "until": "<js predicate on window>", "timeout": 60}, ...]}
"""
import argparse, base64, json, os, socket, struct, subprocess, sys, tempfile, time, urllib.request


class WS:
    """Minimal RFC 6455 client: text frames, client-side masking, fragmentation-aware reads."""

    def __init__(self, url):
        assert url.startswith("ws://")
        host_port, path = url[5:].split("/", 1)
        host, port = host_port.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=120)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.sock.recv(4096)
        if b" 101 " not in resp.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket handshake failed: " + resp.decode(errors="replace")[:200])
        self.buf = b""
        self.msg_id = 0

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_text(self, text):
        data = text.encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        n = len(data)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + mask + masked)

    def recv_text(self):
        message = b""
        while True:
            b0, b1 = self._recv_exact(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv_exact(8))[0]
            payload = self._recv_exact(n)
            if opcode == 0x8:
                raise RuntimeError("websocket closed by peer")
            if opcode == 0x9:  # ping -> pong
                self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            message += payload
            if fin:
                return message.decode()

    def call(self, method, params=None, timeout=120):
        self.msg_id += 1
        mid = self.msg_id
        self.send_text(json.dumps({"id": mid, "method": method, "params": params or {}}))
        t0 = time.time()
        while time.time() - t0 < timeout:
            msg = json.loads(self.recv_text())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
        raise RuntimeError(f"{method}: no reply within {timeout}s")


def evaluate(ws, expression, await_promise=True, timeout=120):
    r = ws.call("Runtime.evaluate", {"expression": expression, "awaitPromise": await_promise, "returnByValue": True}, timeout=timeout)
    if "exceptionDetails" in r:
        ex = r["exceptionDetails"]
        desc = ex.get("exception", {}).get("description") or ex.get("text")
        raise RuntimeError(f"page exception: {desc}")
    return r.get("result", {}).get("value")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", required=True); ap.add_argument("--url", required=True); ap.add_argument("--steps", required=True)
    ap.add_argument("--port", type=int, default=9333)
    a = ap.parse_args()
    spec = json.load(open(a.steps))
    prof = tempfile.mkdtemp(prefix="epiflow_cdp_")
    proc = subprocess.Popen([a.chrome, "--headless=new", "--disable-gpu", "--no-sandbox", f"--user-data-dir={prof}",
                             f"--remote-debugging-port={a.port}", "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = []
    try:
        targets = None
        for _ in range(60):
            try:
                targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{a.port}/json", timeout=2)); break
            except Exception:
                time.sleep(0.5)
        if not targets:
            raise RuntimeError("Chrome did not expose the DevTools port")
        page = next(t for t in targets if t.get("type") == "page")
        ws = WS(page["webSocketDebuggerUrl"])
        ws.call("Page.enable"); ws.call("Runtime.enable")
        ws.call("Page.navigate", {"url": a.url})
        # wait for the page (and its scripts) to load
        for _ in range(100):
            if evaluate(ws, "document.readyState === 'complete' && typeof App !== 'undefined' && typeof ImportPanel !== 'undefined'", await_promise=False):
                break
            time.sleep(0.2)
        time.sleep(0.5)
        for step in spec["steps"]:
            t0 = time.time()
            try:
                evaluate(ws, f"(async () => {{ {step['js']} }})()", await_promise=True, timeout=step.get("timeout", 60) + 30)
                ok = True
                until = step.get("until")
                if until:
                    ok = False
                    deadline = time.time() + step.get("timeout", 60)
                    while time.time() < deadline:
                        if evaluate(ws, f"!!({until})", await_promise=False):
                            ok = True; break
                        time.sleep(0.25)
                log.append({"step": step["name"], "ok": ok, "secs": round(time.time() - t0, 1)})
                if not ok:
                    log.append({"step": step["name"], "note": "condition not met before timeout"})
            except Exception as e:  # keep going so the final state is still reported
                log.append({"step": step["name"], "ok": False, "error": str(e)})
        state = evaluate(ws, spec["state"], await_promise=False)
        print(json.dumps({"state": state, "steps": log}))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    main()
