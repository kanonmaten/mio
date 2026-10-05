#!/usr/bin/env bash
# Checks Mio's local Pianissimo service through authenticated /health. No audio is sent.
# ./check.sh         one check
# ./check.sh --wait  poll for up to 5 minutes until the model is ready
# MIO_EXPECT_REVISION=<sha> also requires that exact model revision to be loaded.
set -euo pipefail

config=/etc/mio-transcription.conf
token="$(sudo sed -n 's/^MIO_TRANSCRIPTION_TOKEN=//p' "$config")"
[[ -n $token ]] || { echo "FEL: ingen token i $config. Kör ./install.sh." >&2; exit 1; }

health() {
    # The token goes to curl on stdin, never into argv or shell history.
    curl --silent --connect-timeout 3 --max-time 10 --write-out '\n%{http_code}' --config - <<EOF
url = "http://127.0.0.1:8765/health"
header = "Authorization: Bearer ${token}"
EOF
}

wait_seconds=0
[[ ${1:-} == --wait ]] && wait_seconds=300
deadline=$((SECONDS + wait_seconds))
while :; do
    response="$(health || true)"
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ $code == 200 && $body == *"\"revision\":\"${MIO_EXPECT_REVISION:-}"* ]]; then
        echo "Redo: $body"
        exit 0
    fi
    if ((SECONDS >= deadline)); then
        if [[ $code == 200 ]]; then reason="annan modellversion än ${MIO_EXPECT_REVISION:0:12} laddad"
        elif [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then reason="HTTP $code"
        else reason="ingen kontakt med 127.0.0.1:8765"; fi
        echo "Inte redo ($reason). Status: sudo systemctl status mio-transcription" >&2
        echo "Logg: sudo journalctl -u mio-transcription -n 50 --no-pager" >&2
        exit 1
    fi
    sleep 5
done
