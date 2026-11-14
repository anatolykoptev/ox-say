"""Live check of ox-stt's per-request terms (needs the real model; not run in CI).

    python3 -I terms_server_live.py <ox-stt> <parakeet model> <silero vad model> <16 kHz mono WAV> <expected written form>

Starts `ox-stt --serve` on a free loopback port, then checks that:
  - POST /transcribe with no X-Ox-Terms decodes as before (200);
  - a malformed, oversize or wrong-alphabet X-Ox-Terms still decodes (200, unboosted) - a bad list never fails a decode;
  - a valid X-Ox-Terms (one spoken form per written form) boosts: the decode answers 200 with the written form
    and a `text_raw` field;
  - POST /sessions with a malformed body still creates a session, and with a valid body creates one that the
    finish re-decode answers (200).
Synthetic audio only. Kills the server it started.
"""
import base64
import http.client
import json
import socket
import struct
import subprocess
import sys
import time


def b64(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


def call(port, method, path, body=b"", headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def main(oxstt, model, vad, wav, want):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    srv = subprocess.Popen([oxstt, "--serve", "--port", str(port), "-m", model, "--vad", vad],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    fails = []
    try:
        for _ in range(300):
            try:
                if call(port, "GET", "/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.5)
        else:
            raise SystemExit("server did not come up")
        audio = open(wav, "rb").read()
        h = {"Content-Type": "audio/wav"}
        good = json.dumps({"alpha": 2, "terms": [want + "\t1\tоксей\tаксей\tоксэй"]}, ensure_ascii=False)

        def check(name, cond):
            print(("ok   " if cond else "FAIL ") + name)
            if not cond:
                fails.append(name)

        st, b = call(port, "POST", "/transcribe", audio, h)
        check("no header decodes", st == 200 and "text" in json.loads(b))
        for name, val in (("garbage header", "!!!not base64!!!"), ("valid base64 of non-JSON", b64("not json")),
                          ("oversize header", "A" * 8000), ("alpha above the cap", b64(json.dumps({"alpha": 1e100, "terms": ["abc"]}))),
                          ("wrong shape", b64(json.dumps({"terms": "abc"})))):
            st, b = call(port, "POST", "/transcribe", audio, {**h, "X-Ox-Terms": val})
            check(name + " still decodes (unboosted)", st == 200 and "text" in json.loads(b) and "text_raw" not in json.loads(b))
        st, b = call(port, "POST", "/transcribe", audio, {**h, "X-Ox-Terms": b64(good)})
        j = json.loads(b) if st == 200 else {}
        check("valid header decodes boosted", st == 200 and "text_raw" in j)
        print("     boosted text:", j.get("text"))
        check("the written form is in the boosted text", want in j.get("text", ""))

        for name, body in (("malformed session body", b"{not json"), ("oversize session body", b"x" * 40000), ("valid session body", good.encode())):
            st, b = call(port, "POST", "/sessions", body, {"Content-Type": "application/json"})
            check(name + " creates a session", st == 200 and "id" in json.loads(b))
            if st == 200:
                sid = json.loads(b)["id"]
                pcm = struct.pack("<%df" % 16000, *([0.0] * 16000))
                st2, _ = call(port, "POST", "/sessions/%s/audio" % sid, pcm, {"Content-Type": "application/octet-stream"})
                st3, b3 = call(port, "POST", "/sessions/%s/finish" % sid, b"{}", {"Content-Type": "application/json"})
                check(name + " session answers audio+finish", st2 == 200 and st3 == 200)
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()
        err = srv.stderr.read().decode(errors="replace")
        for needle in ("оксей", "аксей", "OxSay"):
            if needle in err:
                fails.append("term text in the server's stderr: " + needle)
                print("FAIL term text in stderr:", needle)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main(*sys.argv[1:6])
