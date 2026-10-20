#!/bin/sh
# Collect Vellum + GNOME Shell diagnostics into one text file.
# Usage: ./scripts/collect-crash-report.sh [output-file]
set -u

out="${1:-$HOME/vellum-crash-report-$(date +%Y%m%d-%H%M%S).txt}"
exec >"$out" 2>&1

section() {
    printf '\n===== %s =====\n' "$1"
}

section "Report"
date -Is
uname -a
printf 'session=%s desktop=%s\n' "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}"

section "Vellum"
flatpak info io.github.vellum.Vellum 2>&1 || true
crash_log="$HOME/.var/app/io.github.vellum.Vellum/data/vellum/crash.log"
if [ -f "$crash_log" ]; then
    ls -l "$crash_log"
    cat "$crash_log"
else
    echo "missing: $crash_log"
fi

section "GNOME"
gnome-shell --version 2>&1 || true
gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>&1 || true
systemctl status iio-sensor-proxy.service --no-pager 2>&1 | tail -40 || true

section "Sensors"
if command -v monitor-sensor >/dev/null 2>&1; then
    timeout 5 monitor-sensor 2>&1 || true
else
    echo "monitor-sensor not installed"
fi

section "Coredumps"
coredumpctl list --no-pager 2>&1 | tail -30 || true
coredumpctl info gnome-shell --no-pager 2>&1 | tail -120 || true
coredumpctl info vellum --no-pager 2>&1 | tail -120 || true

section "Current boot errors"
journalctl -b -p err --no-pager 2>&1 | tail -100 || true

section "Previous boot kernel/shell"
journalctl -b -1 -k --no-pager 2>&1 \
    | grep -Ei 'i915|amdgpu|drm|mutter|gnome-shell|iio|orientation|segfault|crash' \
    | tail -160 || true

section "Flatpak"
flatpak remotes --show-details 2>&1 || true
flatpak list --app --columns=application,version,origin 2>&1 | grep -i vellum || true

printf '\nReport written to %s\n' "$out"
