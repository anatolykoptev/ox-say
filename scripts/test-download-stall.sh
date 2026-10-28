#!/bin/bash
# A stalled download must end, not hang: get.sh and fetch-models.sh run real curl against a local
# listener that (a) sends headers and then nothing, (b) trickles below the stall limit, and (c) trickles
# slowly but above it. (a) and (b) must end non-zero within a bound and say the download stalled; (c)
# must finish its download. The stall window is shortened with OX_SAY_STALL_SECS so the test is quick;
# the speed limit itself (1 KB/s) is the script's own. Compatible with /bin/bash 3.2; needs python3.
#
# Run: bash scripts/test-download-stall.sh
#
# Mutations that must turn this RED:
#   * get.sh: delete `--speed-limit 1024 --speed-time "$stall_secs"` from the tarball curl -> the dead
#     listener is never given up on -> "get.sh: a dead download ends" fails (killed by this test's bound)
#   * fetch-models.sh: delete `--speed-limit 1024 --speed-time "$stall_secs"` -> same, "fetch-models.sh: ..." fails
#   * get.sh: delete the `--speed-limit 1024 ...` from the SHA256SUMS curl -> "get.sh: a stalled SHA256SUMS" fails
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

command -v python3 >/dev/null || { echo "python3 not found; skipping"; exit 0; }

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
class H(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode("latin1")
        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
            pass
        path = line.split(" ")[1] if " " in line else ""
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
python3 "$tmp/server.py" > "$tmp/port" 2>/dev/null &
server_pid=$!
n=0; while [ ! -s "$tmp/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
port=$(cat "$tmp/port")
[ -n "$port" ] || { echo "listener did not start"; exit 1; }

export OX_SAY_STALL_SECS=2

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
