#!/usr/bin/env bash
# The whole manual rollout, end to end, with traffic running throughout. This
# only strings together the commands you would type by hand -- read it as the
# runbook. HOLD is how long traffic runs between steps.
#
#   ./demo.sh            # ~25 min, leaves v1 (2P+2D) serving and the probe running
#   ./probe.sh stop && ./rollout.sh clean     # when done
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HOLD="${HOLD:-150}"

step() { printf '\n######## %s\n' "$*"; }
hold() { sleep "$HOLD"; ./probe.sh flush; }

step "1. deploy EPP v0 + p0/d0 (2 prefill, 2 decode)"
./rollout.sh deploy
./logs.sh start
./probe.sh start

step "2. traffic on v0"
./probe.sh mark 2-v0-2p2d
hold

step "3. admit p1/d1 (1 prefill, 1 decode) next to v0"
./probe.sh mark 3-v1-loading
./rollout.sh canary

step "4. traffic on both: expect 67% v0 / 33% v1 and no cross-revision pair"
./probe.sh mark 4-v0-2p2d+v1-1p1d
hold
./rollout.sh status
./pairing.py --label 4-canary || true

step "5. scale p0/d0 down to 1, draining"
./probe.sh mark 5-v0-draining-to-1
./rollout.sh scale v0 1
./probe.sh mark 5-v0-1p1d+v1-1p1d
sleep 60

step "6. scale p1/d1 up to 2"
./probe.sh mark 6-v1-scaling-to-2
./rollout.sh scale v1 2
./probe.sh mark 6-v0-1p1d+v1-2p2d
hold
./rollout.sh status
./pairing.py --label 6-v1-majority || true

step "7. remove p0/d0, draining"
./probe.sh mark 7-v0-draining-to-0
./rollout.sh retire v0
./probe.sh mark 7-v1-2p2d-only
hold
./rollout.sh status
./pairing.py --label 7-final || true

step "verdict"
./report.py | tee results/report.txt || true
