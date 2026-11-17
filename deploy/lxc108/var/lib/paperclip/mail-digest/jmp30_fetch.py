#!/usr/bin/env python3
"""JMP-30: fetch e-mails addressed to caixa-projetos@example.invalid via local Proton
Mail Bridge (IMAP 127.0.0.1:1143, user operador@example.invalid) and write one
digest file (<= 100 words per mail) into /var/lib/paperclip/mail-digest/.

- Dedup via processed.json (UID + Message-ID).
- Password: PAPERCLIP_MAIL_PASSWORD env, else /etc/paperclip-mail.env.
- Writes <digest file> JSON: [{uid, message_id, subject, from, date, summary}].
"""
import email, email.policy, html, json, os, re, socket, sys
from datetime import datetime, timezone
from email.header import decode_header

HOST = os.environ.get("MAIL_IMAP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAIL_IMAP_PORT", "1143"))
_ENV_USER = os.environ.get("MAIL_IMAP_USER")
DIGEST_DIR = "/var/lib/paperclip/mail-digest"
PROCESSED = os.path.join(DIGEST_DIR, "processed.json")
TARGET = "caixa-projetos@example.invalid"


_KNOWN_USER = "operador@example.invalid"


def _resolve_user():
    """Return MAIL_IMAP_USER: env var if valid, else env file, else known good."""
    if _ENV_USER and _ENV_USER.strip():
        return _ENV_USER
    try:
        with open("/etc/paperclip-mail.env") as fh:
            for line in fh:
                m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$', line.strip())
                if m and m.group(1) == "MAIL_IMAP_USER":
                    val = m.group(2).strip('"').strip("'")
                    if val.strip():
                        return val
                    return _KNOWN_USER
    except (PermissionError, FileNotFoundError):
        pass
    return _KNOWN_USER


USER = _resolve_user()


def get_password():
    for var in ("PAPERCLIP_MAIL_PASSWORD", "MAIL_IMAP_PASS"):
        v = os.environ.get(var)
        if v:
            return v
    try:
        with open("/etc/paperclip-mail.env") as fh:
            for line in fh:
                m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$', line.strip())
                if m and re.search(r'(?i)pass', m.group(1)):
                    return m.group(2).strip('"').strip("'")
    except (PermissionError, FileNotFoundError):
        pass
    return None


class IMAP:
    def __init__(self, user, password):
        self.s = socket.create_connection((HOST, PORT), timeout=30)
        self.s.settimeout(360)
        self.buf = b""
        self._op = 0
        self._read()  # greeting
        self._authenticate(user, password.strip())

    def _authenticate(self, user, password):
        """LOGIN plain — funciona no Proton Mail Bridge (AUTHENTICATE PLAIN falha)."""
        tag = f"A{self._op:03d}"
        self._op += 1
        # Escape special characters in user/password per RFC 3501 §9.1
        escaped_user = user.replace("\\", "\\\\").replace('"', '\\"')
        escaped_pass = password.replace("\\", "\\\\").replace('"', '\\"')
        self.s.sendall(f'{tag} LOGIN "{escaped_user}" "{escaped_pass}"\r\n'.encode())
        out = []
        for _ in range(32):
            line = self._read()
            out.append(line)
            if line.startswith(tag):
                break
        resp = "\r\n".join(out)
        if "OK" not in resp:
            raise RuntimeError(f"IMAP LOGIN failed: {resp[-200:]}")

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.s.recv(8192)
            if not chunk:
                raise ConnectionError("IMAP connection closed by server")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("latin-1")

    def _cmd(self, text, timeout=360):
        old_timeout = self.s.gettimeout()
        self.s.settimeout(timeout)
        try:
            self._op += 1
            tag = f"A{self._op:03d}"
            self.s.sendall(f"{tag} {text}\r\n".encode())
            out = []
            still_working = 0
            while True:
                line = self._read()
                out.append(line)
                if "Still working" in line:
                    still_working += 1
                    if still_working > 400:
                        raise RuntimeError(
                            f"Bridge stuck in 'Still working' after {still_working} iterations"
                        )
                if line.startswith(tag):
                    break
            return "\n".join(out)
        finally:
            self.s.settimeout(old_timeout)

    def close(self):
        try:
            self._cmd("LOGOUT")
        except Exception:
            pass
        self.s.close()


def decode_subject(h):
    if not h:
        return ""
    parts = []
    for data, enc in decode_header(h):
        parts.append(data if isinstance(data, str) else data.decode(enc or "utf-8", "replace"))
    return "".join(parts)


def extract_raw(r22_response):
    """Fetch a literal: response contains (* x.y ... (RFC822 n) {n} then n bytes."""
    enc = r22_response.encode("latin-1")
    m = re.search(rb"\{(\d+)\}\r*\n", enc)
    if not m:
        return b""
    n = int(m.group(1))
    pos = m.end()
    return enc[pos:pos + n]


def parse_body(msg):
    body = ""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_maintype() == "text" and not part.get_content_maintype() == "multipart":
                pl = part.get_payload(decode=True)
                if pl:
                    body = pl.decode("utf-8", "replace")
                    break
    else:
        pl = msg.get_payload(decode=True)
        body = pl.decode("utf-8", "replace") if pl else (msg.get_payload() or "")
    return re.sub(r"\s+", " ", body).strip()


def summarize(body, subject, limit_words=98):
    body = re.sub(r"<style.*?</style>|<script.*?</script>", " ", body, flags=re.S | re.I)
    body = re.sub(r"<[^>]+>", " ", body)
    words = html.unescape(body).split()
    if len(words) <= limit_words:
        s = " ".join(words)
    else:
        s = " ".join(words[:limit_words]) + "…"
    return s[:480] if s else f"(corpo vazio) assunto: {subject}"


def load_processed():
    """Returns dict: {"uids": [...], "last_run": ...} or legacy list -> normalized."""
    try:
        with open(PROCESSED) as f:
            data = json.load(f)
    except Exception:
        data = {"uids": []}
    if isinstance(data, list):
        data = {"uids": data}
    data.setdefault("uids", [])
    return data


def _fallback_cached(imap=None):
    """Bridge indisponível — retorna digest em cache quando disponível."""
    digest_path = os.path.join(DIGEST_DIR, "digest-latest.json")
    try:
        with open(digest_path) as f:
            existing = json.load(f)
        print(json.dumps({
            "new": 0,
            "digest": digest_path,
            "note": "bridge_indisponivel_usando_cache",
            "cached_mails": len(existing.get("new_mails", [])),
        }, ensure_ascii=False))
        return 0
    except FileNotFoundError:
        print(json.dumps({"new": 0, "digest": digest_path, "note": "sem_digest_cache"}, ensure_ascii=False))
        return 0


def find_folder(imap):
    names = []
    for line in imap._cmd('LIST "" "*"').splitlines():
        m = re.search(r'"([^"]*)"\s*$', line)
        if m:
            names.append(m.group(1))
    matches = [n for n in names if n.split("/")[-1].lower() == "caixa-projetos"]
    matches.sort(key=lambda n: (not n.startswith("Folders/"), n))
    return matches[0] if matches else None


def _main_impl():
    password = get_password()
    if not password:
        print("BLOCKED: no IMAP password (env PAPERCLIP_MAIL_PASSWORD or /etc/paperclip-mail.env)")
        return 2
    imap = IMAP(USER, password)
    processed = load_processed()
    seen = set(processed["uids"])
    try:
        folder = find_folder(imap)
        unseens = []
        mailbox_key = ""
        if folder:
            ex = imap._cmd(f'EXAMINE "{folder}"')
            uv = re.search(r"UIDVALIDITY (\d+)", ex)
            mailbox_key = f"caixa-projetos:{uv.group(1) if uv else '0'}:"
            for line in imap._cmd("UID SEARCH ALL").splitlines():
                m = re.match(r"^\* SEARCH (.*)$", line)
                if m and m.group(1):
                    unseens.extend(m.group(1).split())
        new = []
        if not folder:
            total = 0
            for line in imap._cmd("EXAMINE INBOX").splitlines():
                m = re.search(r"(\d+)\s+EXISTS", line)
                if m:
                    total = int(m.group(1))
            start = max(1, total - 500) if total else 1
            rng = f"{start}:{total}" if total else "1:1"
            r = imap._cmd(f"UID FETCH {rng} (UID BODY.PEEK[HEADER.FIELDS (TO CC)])")
            for muid in re.finditer(rb"\* \d+ FETCH \(\s*UID (\d+)", r.encode("latin-1")):
                rest = r.encode("latin-1")[muid.end():]
                mclose = re.search(rb"\)\r?\n", rest)
                chunk = rest[:mclose.start()] if mclose else rest[:4096]
                if TARGET.encode() in chunk:
                    unseens.append(muid.group(1).decode())
            unseens.sort(key=int, reverse=True)
        candidates = [u for u in unseens if f"{mailbox_key}uid:{u}" not in seen]
        candidates.sort(key=int, reverse=True)
        for uid in candidates:
            r2 = imap._cmd(f"UID FETCH {uid} (BODY.PEEK[])")
            raw = extract_raw(r2)
            if not raw:
                continue
            try:
                msg = email.message_from_bytes(raw)
            except Exception:
                continue
            addrs = " ".join((msg.get_all("To") or []) + (msg.get_all("Cc") or []) + (msg.get_all("Bcc") or []))
            addrs = addrs.lower()
            is_target = bool(folder) or (TARGET in addrs
                         or TARGET in (msg.get("Envelope-To") or "").lower())
            subject = decode_subject(msg.get("Subject"))
            body = parse_body(msg)
            if is_target:
                new.append({
                    "uid": uid,
                    "message_id": msg.get("Message-ID", ""),
                    "from": msg.get("From", ""),
                    "date": msg.get("Date", ""),
                    "subject": subject,
                    "summary": summarize(body, subject),
                })
            processed["uids"].append(f"{mailbox_key}uid:{uid}")
        processed["last_run"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        imap.close()
        with open(PROCESSED, "w") as f:
            json.dump(processed, f)
        digest = os.path.join(DIGEST_DIR, "digest-latest.json")
        with open(digest, "w") as f:
            json.dump({"new_mails": new, "digest_path": digest}, f, ensure_ascii=False, indent=2)
        print(json.dumps({"new": len(new), "digest": digest}, ensure_ascii=False))
        return 0
    except (RuntimeError, TimeoutError) as e:
        err_str = str(e)
        if "Still working" in err_str or isinstance(e, TimeoutError):
            print(f"WARN: bridge indisponível ({type(e).__name__}: {err_str[:80]}) — usando cache", flush=True)
            return _fallback_cached(imap)
        raise


def main():
    try:
        return _main_impl()
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        digest = os.path.join(DIGEST_DIR, "digest-latest.json")
        try:
            with open(digest, "w") as f:
                json.dump({"new_mails": [], "error": err, "digest_path": digest}, f, ensure_ascii=False, indent=2)
        except OSError:
            pass
        print(json.dumps({"new": 0, "error": err, "digest": digest}, ensure_ascii=False))
        return 0


if __name__ == "__main__":
    sys.exit(main())
