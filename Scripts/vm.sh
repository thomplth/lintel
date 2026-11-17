#!/bin/bash
# Drives Lintel inside debut's macOS Tart guest, so GUI checks never touch the developer's own desktop.
#
#   Scripts/vm.sh session        Wait for debut's Tart queue, boot the guest headless, and hold it until `stop`.
#                                Run it in the background; it prints "VM ready" once the guest answers.
#   Scripts/vm.sh install        Bundle this checkout, install it in the guest with a fresh layout, launch it and
#                                hold the bar open.
#   Scripts/vm.sh run '<cmd>'    Run a shell command in the guest's logged-in session.
#   Scripts/vm.sh lintel '<json>'  Send a `Lintel ctl` command; `state` prints the reply.
#   Scripts/vm.sh input <args>   Synthesise pointer and keyboard input in the guest (see Scripts/vm-input.swift).
#   Scripts/vm.sh shot <name>    Screenshot the guest (pointer included) and print the host path of the PNG.
#   Scripts/vm.sh stop           Stop the guest and leave the queue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEBUT_DIR="${LINTEL_DEBUT_DIR:-$HOME/Developer/debut}"
VM="${LINTEL_VM:-debut-e2e-27}"
SHARE="${LINTEL_VM_SHARE:-$HOME/Library/Caches/Debut/TartE2E-27}"
HOST_DIR="$SHARE/lintel"
GUEST_SHARE="/Volumes/My Shared Files/lintel"
RELEASE_FILE="$HOST_DIR/.release"

guest() {
    local ip
    if ip="$(tart ip "$VM" --wait 15 2>/dev/null)" && [[ -n "$ip" ]]; then
        ssh -q -i "$SHARE/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$SHARE/known_hosts" "admin@$ip" "$1"
        return
    fi
    # Without DHCP, enter over vsock and hop through loopback SSH, as debut's E2E does: the guest granted
    # Accessibility and Screen Recording to sshd, so input and screenshots only work from an SSH session.
    tart exec "$VM" /bin/bash -c '
        exec ssh -q -i "$HOME/.ssh/id_ed25519_debut_e2e_loopback" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new admin@127.0.0.1 "$1"
    ' _ "$1"
}

session() {
    # shellcheck source=/dev/null
    source "$DEBUT_DIR/Scripts/tart-queue.sh"
    mkdir -p "$HOST_DIR"
    rm -f "$RELEASE_FILE"
    tart_queue_enter "lintel GUI testing ($(basename "$PROJECT_DIR"))"
    trap 'tart stop "$VM" >/dev/null 2>&1 || true; tart_queue_leave' EXIT
    if ! tart exec "$VM" /usr/bin/true >/dev/null 2>&1; then
        nohup tart run --no-graphics --no-audio --no-clipboard --no-pointer --no-keyboard --dir="$SHARE" "$VM" \
            >"$HOST_DIR/tart-vm.log" 2>&1 </dev/null &
        for _ in {1..90}; do
            tart exec "$VM" /usr/bin/true >/dev/null 2>&1 && break
            sleep 2
        done
    fi
    tart exec "$VM" /usr/bin/true
    echo "VM ready"
    while [[ ! -f "$RELEASE_FILE" ]]; do sleep 3; done
}

install() {
    "$SCRIPT_DIR/bundle.sh"
    mkdir -p "$HOST_DIR"
    rm -rf "$HOST_DIR/Lintel.app"
    ditto "$PROJECT_DIR/build/Lintel.app" "$HOST_DIR/Lintel.app"
    xcrun --sdk macosx swiftc -O -o "$HOST_DIR/vm-input" "$SCRIPT_DIR/vm-input.swift"
    guest "
        L=~/lintel/Lintel.app/Contents/MacOS/Lintel
        [[ -x \$L ]] && \$L ctl '{\"cmd\":\"quit\"}' && sleep 1.5
        rm -rf ~/lintel && mkdir ~/lintel
        ditto '$GUEST_SHARE/Lintel.app' ~/lintel/Lintel.app && cp '$GUEST_SHARE/vm-input' ~/lintel/vm-input
        rm -f ~/Library/Application\\ Support/Lintel/layout.json
        open ~/lintel/Lintel.app && sleep 5
        \$L ctl '{\"cmd\":\"close-settings\"}'; \$L ctl '{\"cmd\":\"hold\"}'
    "
    echo "Installed and launched in $VM"
}

case "${1:-}" in
    session) session ;;
    install) install ;;
    run) guest "$2" ;;
    lintel)
        if [[ "$2" == *'"state"'* ]]; then
            guest "~/lintel/Lintel.app/Contents/MacOS/Lintel ctl '${2%\}},\"path\":\"/tmp/lintel-state.json\"}'; sleep 0.5; cat /tmp/lintel-state.json"
        else
            guest "~/lintel/Lintel.app/Contents/MacOS/Lintel ctl '$2'"
        fi
        ;;
    input) shift; guest "~/lintel/vm-input $*" ;;
    shot)
        guest "screencapture -x -C '$GUEST_SHARE/$2.png'"
        echo "$HOST_DIR/$2.png"
        ;;
    stop) mkdir -p "$HOST_DIR"; touch "$RELEASE_FILE" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
