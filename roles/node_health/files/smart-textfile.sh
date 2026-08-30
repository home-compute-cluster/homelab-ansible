#!/usr/bin/env bash
# Managed by Ansible (roles/node_health). Do not hand-edit.
#
# Writes SMART/NVMe health as Prometheus textfile-collector metrics.
# node-exporter picks these up via --collector.textfile.directory.
set -euo pipefail

OUT=/var/lib/node_exporter/textfile_collector/smart.prom
TMP="${OUT}.$$"
trap 'rm -f "$TMP"' EXIT

{
  echo "# HELP smart_device_health 1 = PASSED, 0 = FAILED"
  echo "# TYPE smart_device_health gauge"
  echo "# HELP smart_device_temp_celsius Drive temperature"
  echo "# TYPE smart_device_temp_celsius gauge"
  echo "# HELP smart_device_percentage_used NVMe endurance consumed (percent)"
  echo "# TYPE smart_device_percentage_used gauge"
  for d in $(lsblk -dno PATH,TYPE | awk '$2=="disk"{print $1}'); do
    j=$(smartctl -a -j "$d" 2>/dev/null) || continue
    ok=$(echo "$j"  | jq -r '.smart_status.passed // empty')
    tmp=$(echo "$j" | jq -r '.temperature.current // empty')
    pct=$(echo "$j" | jq -r '.nvme_smart_health_information_log.percentage_used // empty')
    [ -n "$ok" ]  && echo "smart_device_health{device=\"$d\"} $([ "$ok" = true ] && echo 1 || echo 0)"
    [ -n "$tmp" ] && echo "smart_device_temp_celsius{device=\"$d\"} $tmp"
    [ -n "$pct" ] && echo "smart_device_percentage_used{device=\"$d\"} $pct"
  done
} > "$TMP"

# Write to $TMP then mv. The textfile-collector docs are explicit that files
# must appear atomically; otherwise node-exporter scrapes a half-written .prom
# and emits a parse error that looks like an intermittent scrape failure (F11).
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
