#!/usr/bin/env python3
"""Throwaway record-and-compare server for spike 01a. Stdlib only.

    python3 server.py            # http://127.0.0.1:8765

Records/uploads land in audio/, whisper-cli outputs in out/clipN/.
"""
import json
import re
import subprocess
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST, PORT = "127.0.0.1", 8765
ROOT = Path(__file__).resolve().parent
AUDIO, MODELS, OUT = ROOT / "audio", ROOT / "models", ROOT / "out"
CLI = ROOT / "whisper.cpp/build/bin/whisper-cli"

PROMPT = "Umm, so, I-I was like, hmm... uh, you know, I— I mean."
# whisper-cli defaults to beam search (bs 5), so S1/S2 force greedy to keep S3 distinct.
# Non-speech token suppression (-sns) is off by default; nothing here turns it on.
SETTINGS = {
    "S1": {"label": "greedy, temp 0", "args": ["-bs", "1", "-tp", "0"]},
    "S2": {"label": "S1 + disfluent prompt", "args": ["-bs", "1", "-tp", "0", "--prompt", PROMPT]},
    "S3": {"label": "S2 + beam 5", "args": ["-bs", "5", "-tp", "0", "--prompt", PROMPT]},
}
EXTS = {"audio/webm": "webm", "audio/ogg": "ogg", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
        "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac"}
CLIP_RE = re.compile(r"^clip\d+$")

gpu_lock = threading.Lock()


def models():
    return {p.name[len("ggml-"):-len(".bin")]: p for p in sorted(MODELS.glob("ggml-*.bin"))}


def clip_ids():
    ids = [p.stem for p in AUDIO.glob("clip*.wav") if CLIP_RE.match(p.stem)]
    return sorted(ids, key=lambda s: int(s[4:]))


def wav_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def clip_state(cid):
    runs = []
    for meta in sorted((OUT / cid).glob("*.meta.json")):
        m = json.loads(meta.read_text())
        j = meta.with_name(meta.name.replace(".meta.json", ".json"))
        m["segments"] = load_segments(j) if j.exists() else []
        runs.append(m)
    return {"id": cid, "duration": round(wav_seconds(AUDIO / f"{cid}.wav"), 2), "runs": runs}


def load_segments(path):
    # whisper-cli's JSON can contain invalid UTF-8 when a multibyte char is split across tokens
    data = json.loads(path.read_bytes().decode("utf-8", "replace"))
    return [{"from": s["offsets"]["from"], "to": s["offsets"]["to"], "text": s["text"]}
            for s in data.get("transcription", [])]


def timing(log, name):
    m = re.search(rf"{name} time =\s*([\d.]+) ms", log)
    return float(m.group(1)) / 1000 if m else None


def run_cell(cid, model, setting):
    mpath = models()[model]
    wav = AUDIO / f"{cid}.wav"
    (OUT / cid).mkdir(parents=True, exist_ok=True)
    base = OUT / cid / f"{model}__{setting}"
    cmd = [str(CLI), "-m", str(mpath), "-f", str(wav), "-otxt", "-oj", "-of", str(base),
           *SETTINGS[setting]["args"]]
    with gpu_lock:
        t0 = time.monotonic()
        p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
        wall = time.monotonic() - t0
    log = p.stdout + p.stderr
    Path(f"{base}.log").write_text(" ".join(cmd) + "\n\n" + log)
    if p.returncode != 0:
        raise RuntimeError(f"whisper-cli exit {p.returncode}:\n{log[-2000:]}")
    dur = wav_seconds(wav)
    load, total = timing(log, "load"), timing(log, "total")
    infer = total - load if total and load else wall
    meta = {"model": model, "setting": setting, "label": SETTINGS[setting]["label"],
            "args": SETTINGS[setting]["args"], "size_mb": round(mpath.stat().st_size / 1e6),
            "wall_s": round(wall, 2), "infer_s": round(infer, 2), "rtf": round(infer / dur, 3),
            "at": time.strftime("%Y-%m-%d %H:%M:%S")}
    Path(f"{base}.meta.json").write_text(json.dumps(meta, indent=1))
    meta["segments"] = load_segments(Path(f"{base}.json"))
    return meta


def save_upload(body, ctype, ext_hint):
    ext = EXTS.get(ctype.split(";")[0].strip()) or re.sub(r"[^a-z0-9]", "", ext_hint.lower())[:5] or "bin"
    AUDIO.mkdir(exist_ok=True)
    n = max([int(c[4:]) for c in clip_ids()] + [0]) + 1
    while list(AUDIO.glob(f"clip{n}.*")):
        n += 1
    cid = f"clip{n}"
    src = AUDIO / f"{cid}.orig.{ext}"
    src.write_bytes(body)
    p = subprocess.run(["ffmpeg", "-nostdin", "-y", "-i", str(src), "-ar", "16000", "-ac", "1",
                        "-c:a", "pcm_s16le", str(AUDIO / f"{cid}.wav")], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"ffmpeg failed:\n{p.stderr[-2000:]}")
    return cid


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def route(self, method):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        try:
            if method == "GET" and not parts:
                return self.send(200, (ROOT / "index.html").read_bytes(), "text/html; charset=utf-8")
            if method == "GET" and parts == ["api", "state"]:
                return self.send(200, {
                    "cli": CLI.exists(),
                    "models": [{"name": k, "size_mb": round(v.stat().st_size / 1e6)} for k, v in models().items()],
                    "settings": [{"id": k, **v} for k, v in SETTINGS.items()],
                    "clips": clip_ids()})
            if parts[:2] == ["api", "clips"]:
                if method == "POST" and len(parts) == 2:
                    cid = save_upload(self.body(), self.headers.get("Content-Type", ""),
                                      self.headers.get("X-Ext", ""))
                    return self.send(200, {"id": cid})
                cid = parts[2] if len(parts) > 2 else ""
                if not CLIP_RE.match(cid) or not (AUDIO / f"{cid}.wav").exists():
                    return self.send(404, {"error": "no such clip"})
                rest = parts[3:]
                if method == "GET" and not rest:
                    return self.send(200, clip_state(cid))
                if method == "GET" and rest == ["audio"]:
                    return self.send(200, (AUDIO / f"{cid}.wav").read_bytes(), "audio/wav")
                if method == "POST" and rest == ["run"]:
                    req = json.loads(self.body())
                    if req.get("model") not in models() or req.get("setting") not in SETTINGS:
                        return self.send(400, {"error": "unknown model or setting"})
                    if not CLI.exists():
                        return self.send(500, {"error": f"{CLI} not built"})
                    return self.send(200, run_cell(cid, req["model"], req["setting"]))
            self.send(404, {"error": "not found"})
        except Exception as e:  # throwaway tool: surface everything to the page
            self.send(500, {"error": str(e)})

    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
