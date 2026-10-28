#!/bin/bash
# A stalled download must end, not hang: get.sh and fetch-models.sh run real curl against a local
# listener that (a) sends headers and then nothing, (b) trickles below the stall limit, and (c) trickles
# slowly but above it. (a) and (b) must end non-zero within a bound and say the download stalled; (c)
# must finish its download. The stall window is shortened with OX_SAY_STALL_SECS so the test is quick;
# the speed limit itself (1 KB/s) is the script's own. Compatible with /bin/bash 3.2; needs python3 (fails without it; see below).
#
# Run: bash scripts/test-download-stall.sh
#
# Mutations that must turn this RED:
#   * get.sh: delete `--speed-limit 1024 --speed-time "$stall_secs"` from the tarball curl -> the dead
#     listener is never given up on -> "get.sh: a dead download ends" fails (killed by this test's bound)
#   * fetch-models.sh: delete `--speed-limit 1024 --speed-time "$stall_secs"` -> same, "fetch-models.sh: ..." fails
#   * get.sh: delete the `--speed-limit 1024 ...` from the SHA256SUMS curl -> "get.sh: a stalled SHA256SUMS" fails
#   * delete the python3 `if ! command -v` block's `exit 1` lines (or make it `exit 0`) -> run with python3 hidden
#     (PATH without it): "python3 not found" must exit 1, also with OX_SAY_TEST_SKIP_STALL=1 when CI is set
#   * fetch-models.sh: in fetch_part drop `408 | 429 | 5??) ;;` (so a 22 returns at once) -> the 503 and 429 cases fail
#   * fetch-models.sh: heal on every 22 (`[ "$rc" -eq 22 ]` without the 412/416 test) -> the 503-always and 404 cases
#     fail (the .part is deleted)
#   * either script: raise --speed-limit above 2000 -> the healthy trickle (~2 KB/s) is killed -> "healthy" fails
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-stalltest.XXXXXX")
fails=0
server_pid=
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    find "$tmp" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# The listener needs python3. A missing python3 must not turn the suite green unseen: it fails, with the reason, unless
# OX_SAY_TEST_SKIP_STALL=1 says "skip" on purpose. In CI ($CI set) the skip is not honoured at all.
if ! command -v python3 >/dev/null; then
    if [ -n "${CI:-}" ]; then
        echo "FAIL python3 not found in CI: the stall test needs it for its local listener; install it on the runner" >&2
        exit 1
    fi
    if [ "${OX_SAY_TEST_SKIP_STALL:-0}" = 1 ]; then
        echo "python3 not found; skipping (OX_SAY_TEST_SKIP_STALL=1)"
        exit 0
    fi
    echo "FAIL python3 not found: the stall test needs it for its local listener. Install it, or set OX_SAY_TEST_SKIP_STALL=1 to skip it on a machine that has none (never honoured when CI is set)" >&2
    exit 1
fi

# bounded SECS CMD...: run CMD, kill it after SECS; exit status 124 when it was killed.
bounded() {
    local secs=$1; shift
    "$@" > "$tmp/out" 2>&1 &
    local pid=$! n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [ "$n" -gt $((secs * 10)) ]; then
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
    done
    wait "$pid"
}

# Listener: /stall sends headers, then nothing; /slow trickles 50 B every 0.5 s (100 B/s, below the limit);
# /ok trickles 200 B every 0.1 s (about 2 KB/s, above it) for 6000 bytes. Anything else: 404.
cat > "$tmp/server.py" <<'PY'
import socketserver, sys, time
LOG = sys.argv[1]
SEEN = {}
BODY = b"z" * 6000
class H(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode("latin1")
        rng = ""
        while True:
            h = self.rfile.readline()
            if h in (b"\r\n", b"\n", b""):
                break
            if h.lower().startswith(b"range:"):
                rng = h.decode("latin1").split(":", 1)[1].strip()
        path = line.split(" ")[1] if " " in line else ""
        # /once<status>/x answers <status> to its first request and the body after; /always<status>/x always;
        # /range<status>/x answers <status> to a Range request and the whole body to a plain one.
        # Every request is logged as "<path> <Range header or ->".
        with open(LOG, "a") as f:
            f.write(path + " " + (rng or "-") + "\n")
        SEEN[path] = SEEN.get(path, 0) + 1
        for kind in ("once", "always", "range"):
            if path.startswith("/" + kind):
                status = path[len(kind) + 1:len(kind) + 4]
                fail = (kind == "once" and SEEN[path] == 1) or kind == "always" or (kind == "range" and rng)
                if fail:
                    self.wfile.write(("HTTP/1.1 %s X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % status).encode())
                    return
                start = int(rng.split("=")[1].split("-")[0]) if rng else 0
                body = BODY[start:]
                head = "HTTP/1.1 %s OK\r\nContent-Length: %d\r\nConnection: close\r\n" % ("206" if rng else "200", len(body))
                if rng:
                    head += "Content-Range: bytes %d-%d/%d\r\n" % (start, len(BODY) - 1, len(BODY))
                self.wfile.write((head + "\r\n").encode() + body)
                return
        if "/mixed/" in path:
            path = "/stall" if path.endswith("SHA256SUMS") else "/ok"
        try:
            if path.startswith(("/stall", "/slow")):
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n"); self.wfile.flush()
                if path.startswith("/stall"):
                    time.sleep(120)
                else:
                    for _ in range(2000):
                        self.wfile.write(b"x" * 50); self.wfile.flush(); time.sleep(0.5)
            elif path.startswith("/ok"):
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 6000\r\n\r\n"); self.wfile.flush()
                for _ in range(30):
                    self.wfile.write(b"y" * 200); self.wfile.flush(); time.sleep(0.1)
            else:
                self.wfile.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
s = S(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$tmp/server.py" "$tmp/reqlog" > "$tmp/port" 2>/dev/null &
server_pid=$!
n=0; while [ ! -s "$tmp/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
port=$(cat "$tmp/port")
[ -n "$port" ] || { echo "listener did not start"; exit 1; }

export OX_SAY_STALL_SECS=2
export OX_SAY_RETRY_SLEEP_UNIT=0

# --- fetch-models.sh: real curl, URL rewritten to the listener by a shim ---
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<SHIM
#!/bin/bash
args=()
for a in "\$@"; do
    case \$a in https://*) a="http://127.0.0.1:$port/\$(cat "$tmp/path")" ;; esac
    args+=("\$a")
done
exec /usr/bin/curl "\${args[@]}"
SHIM
chmod +x "$tmp/bin/curl"

echo stall > "$tmp/path"
start=$(date +%s)
PATH="$tmp/bin:$PATH" OX_SAY_MODELS_FROM= bounded 60 bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/d1"; rc=$?
took=$(( $(date +%s) - start ))
out=$(cat "$tmp/out")
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then pass "fetch-models.sh: a dead download ends non-zero (exit $rc, ${took}s)"; else fail "fetch-models.sh: a dead download ends (exit $rc after ${took}s)"; fi
case $out in *stalled*|*"curl exit"*) pass "fetch-models.sh: the stall is named" ;; *) fail "fetch-models.sh: no stall message: $out" ;; esac

echo ok > "$tmp/path"
PATH="$tmp/bin:$PATH" OX_SAY_MODELS_FROM= bounded 60 bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/d2"; rc=$?
out=$(cat "$tmp/out")
case $out in *"checksum mismatch"*) pass "fetch-models.sh: a healthy slow trickle completes its download" ;; *) fail "fetch-models.sh: healthy trickle did not finish (exit $rc): $out" ;; esac

# --- fetch-models.sh: HTTP errors, with real curl and a real status line ---
# fetch <path>: run the notes fetch against /<path>; the destination is $tmp/h-<n>, the .part pre-seeded when $seed is set.
hn=0
fetch_http() {
    hn=$((hn + 1)); hd="$tmp/h-$hn"; mkdir -p "$hd"
    echo "$1" > "$tmp/path"
    : > "$tmp/reqlog"
    if [ -n "${seed:-}" ]; then printf '%s' "$seed" > "$hd/Qwen3.5-4B-Q4_K_M.gguf.part"; fi
    PATH="$tmp/bin:$PATH" OX_SAY_MODELS_FROM= bounded 60 bash "$root/scripts/fetch-models.sh" --notes-only "$hd"; rc=$?
    out=$(cat "$tmp/out"); reqs=$(wc -l < "$tmp/reqlog" | tr -d ' ')
}
part="Qwen3.5-4B-Q4_K_M.gguf.part"

seed= fetch_http once503/fresh
case $out in *"checksum mismatch"*) pass "fetch-models.sh: a 503 on a fresh fetch is retried and the download completes" ;; *) fail "fetch-models.sh: 503 once, fresh (exit $rc): $out" ;; esac
[ "$reqs" = 2 ] && pass "fetch-models.sh: one retry after the 503 (2 requests)" || fail "fetch-models.sh: 503 once, fresh: $reqs requests"

seed= fetch_http once429/fresh
case $out in *"checksum mismatch"*) pass "fetch-models.sh: a 429 is retried and the download completes" ;; *) fail "fetch-models.sh: 429 once (exit $rc): $out" ;; esac

seed=$(head -c 2000 /dev/zero | tr '\0' z) fetch_http once503/resume
case $out in *"checksum mismatch"*) pass "fetch-models.sh: a 503 on a resume is retried and the download completes" ;; *) fail "fetch-models.sh: 503 once, resume (exit $rc): $out" ;; esac
if [ "$reqs" = 2 ] && [ "$(grep -c ' bytes=2000-$' "$tmp/reqlog")" = 2 ]; then
    pass "fetch-models.sh: both requests of the resume carry Range from byte 2000 (the .part was not dropped)"
else
    fail "fetch-models.sh: 503 once, resume: $(cat "$tmp/reqlog")"
fi

seed=$(head -c 2000 /dev/zero | tr '\0' z) fetch_http always503/resume
if [ "$rc" -ne 0 ] && [ "$reqs" = 4 ] && [ "$(wc -c < "$hd/$part" | tr -d ' ')" = 2000 ]; then
    pass "fetch-models.sh: a 503 that never ends stops after 4 requests, naming it, with the 2000-byte .part kept"
else
    fail "fetch-models.sh: 503 always (exit $rc, $reqs requests, part $(wc -c < "$hd/$part" 2>/dev/null))"
fi
case $out in *"HTTP 503"*) pass "fetch-models.sh: the failure names HTTP 503" ;; *) fail "fetch-models.sh: no HTTP 503 in: $out" ;; esac

seed=$(head -c 2000 /dev/zero | tr '\0' z) fetch_http always404/resume
if [ "$rc" -ne 0 ] && [ "$reqs" = 1 ] && [ "$(wc -c < "$hd/$part" | tr -d ' ')" = 2000 ]; then
    pass "fetch-models.sh: a 404 on a resume is not retried and keeps the .part (a fresh request would 404 too)"
else
    fail "fetch-models.sh: 404 (exit $rc, $reqs requests, part $(wc -c < "$hd/$part" 2>/dev/null))"
fi

seed=$(head -c 2000 /dev/zero | tr '\0' z) fetch_http range412/resume
case $out in *"checksum mismatch"*) pass "fetch-models.sh: a resume the server refuses (412) falls back to one fresh download" ;; *) fail "fetch-models.sh: 412 on resume (exit $rc): $out" ;; esac
if [ "$reqs" = 2 ] && sed -n 1p "$tmp/reqlog" | grep -q ' bytes=2000-$' && sed -n 2p "$tmp/reqlog" | grep -q ' -$'; then
    pass "fetch-models.sh: the fallback request carries no Range"
else
    fail "fetch-models.sh: 412 on resume: $(cat "$tmp/reqlog")"
fi

# --- get.sh: real curl against OX_SAY_GET_URL; needs macOS (it refuses elsewhere) ---
if [ "$(uname -s)" = Darwin ]; then
    mkdir -p "$tmp/fake"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/fake/ffmpeg"; chmod +x "$tmp/fake/ffmpeg"
    asset=ox-say-macos-x86_64.tar.gz
    [ "$(uname -m)" = arm64 ] && asset=ox-say-macos-arm64.tar.gz
    # URL prefixes /stall /slow /ok serve every file under them, so each case is a base URL.
    for mode in stall slow; do
        start=$(date +%s)
        PATH="$tmp/fake:$PATH" OX_SAY_GET_URL="http://127.0.0.1:$port/$mode" bounded 60 sh "$root/get.sh"; rc=$?
        took=$(( $(date +%s) - start ))
        out=$(cat "$tmp/out")
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then pass "get.sh: a dead download ends ($mode, exit $rc, ${took}s)"; else fail "get.sh: a dead download ends ($mode: exit $rc after ${took}s)"; fi
        case $out in *stalled*) pass "get.sh: the stall is named ($mode)" ;; *) fail "get.sh: no stall message ($mode): $out" ;; esac
    done
    PATH="$tmp/fake:$PATH" OX_SAY_GET_URL="http://127.0.0.1:$port/ok" bounded 60 sh "$root/get.sh"; rc=$?
    out=$(cat "$tmp/out")
    # the 6000 bytes arrive, then the SHA256SUMS fetch answers the same 6000 bytes: no checksum line for the asset
    case $out in *"no checksum listed"*) pass "get.sh: a healthy slow trickle completes both downloads" ;; *) fail "get.sh: healthy trickle did not finish (exit $rc): $out" ;; esac

    # The tarball is healthy and SHA256SUMS stalls: that curl needs the guard too.
    start=$(date +%s)
    PATH="$tmp/fake:$PATH" OX_SAY_GET_URL="http://127.0.0.1:$port/mixed" bounded 60 sh "$root/get.sh"; rc=$?
    took=$(( $(date +%s) - start ))
    out=$(cat "$tmp/out")
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then pass "get.sh: a stalled SHA256SUMS ends (exit $rc, ${took}s)"; else fail "get.sh: a stalled SHA256SUMS ends (exit $rc after ${took}s)"; fi
    case $out in *"SHA256SUMS"*stalled*|*stalled*"SHA256SUMS"*) pass "get.sh: the SHA256SUMS stall is named" ;; *) fail "get.sh: no SHA256SUMS stall message: $out" ;; esac
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
