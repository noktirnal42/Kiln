#!/usr/bin/env python3
"""A tiny language server for tests: answers initialize, reports one diagnostic on didOpen/didChange, resolves definition and completion."""
import json, sys

def read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: return None
        line = line.decode().strip()
        if not line: break
        k, v = line.split(":", 1); headers[k.lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))

def send(obj):
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body); sys.stdout.buffer.flush()

while True:
    m = read()
    if m is None: break
    method = m.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {}}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        uri = (m["params"]["textDocument"]["uri"])
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": [
            {"range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 9}}, "severity": 1, "message": "stub error"}]}})
    elif method == "textDocument/definition":
        send({"jsonrpc": "2.0", "id": m["id"], "result": [{"uri": m["params"]["textDocument"]["uri"], "range": {"start": {"line": 7, "character": 1}, "end": {"line": 7, "character": 4}}}]})
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"items": [{"label": "alpha"}, {"label": "beta", "insertText": "beta()"}]}})
    elif method == "exit":
        break
    elif "id" in m:
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
