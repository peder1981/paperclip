#!/usr/bin/env python3
"""d1:3b decision microservice: POST /decide {"text": ..., "question": ...} -> {"verdict","confidence","raw"}"""
import json, re, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/decide":
            self.send_response(404); self.end_headers(); return
        try:
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n))
            text, q = (d.get("text") or "")[:14000], (d.get("question") or "")[:500]
            p = subprocess.run(["ollama", "run", "d1:3b", "--ask", q],
                               input=text, capture_output=True, text=True, timeout=60)
            raw = (p.stdout or p.stderr).strip()
            m = re.search(r"(yes|no)\s+(\d+)%", raw, re.I)
            out = {"verdict": m.group(1).lower() if m else "unknown",
                   "confidence": int(m.group(2)) / 100 if m else None, "raw": raw[:500]}
            body = json.dumps(out).encode()
            self.send_response(200)
        except Exception as e:
            body = json.dumps({"verdict": "error", "error": str(e)[:300]}).encode()
            self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass

HTTPServer(("0.0.0.0", 11435), H).serve_forever()
