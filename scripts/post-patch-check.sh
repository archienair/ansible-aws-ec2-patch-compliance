#!/bin/bash
# post-patch-check.sh
# Runs 10 minutes after reboot via cron: @reboot sleep 600 && /opt/scripts/post-patch-check.sh
# Logs results locally and to syslog (picked up by Splunk UF)

HOSTNAME=$(hostname)
DATE=$(date +%Y-%m-%d)
LOGFILE="/var/log/post-patch-check-${DATE}.log"
ERRORS=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

check_service() {
  if systemctl is-active --quiet "$1"; then
    log "OK: $1 is running"
  else
    log "FAIL: $1 is NOT running — attempting restart"
    systemctl start "$1"
    sleep 3
    if systemctl is-active --quiet "$1"; then
      log "RECOVERED: $1 restarted successfully"
    else
      log "CRITICAL: $1 failed to restart on $HOSTNAME"
      ((ERRORS++))
    fi
  fi
}

check_disk() {
  df -H | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{print $5 " " $6}' | while read usage mount; do
    val="${usage%\%}"
    if [ "$val" -gt 85 ]; then
      log "WARN: Disk usage on $mount is at ${val}%"
      ((ERRORS++))
    fi
  done
}

log "=========================================="
log "POST-PATCH HEALTH CHECK: $HOSTNAME"
log "Kernel: $(uname -r)"
log "Uptime: $(uptime -p)"
log "=========================================="

# Check critical services
for svc in sshd crond amazon-ssm-agent; do
  check_service "$svc"
done

# Check disk
check_disk

# Check load average
LOAD=$(awk '{print $1}' /proc/loadavg)
log "Load average (1m): $LOAD"

# Final result
if [ "$ERRORS" -eq 0 ]; then
  log "RESULT: PASSED — all checks healthy on $HOSTNAME"
  logger -t post-patch-check "PATCH HEALTH OK on $HOSTNAME — kernel: $(uname -r)"
else
  log "RESULT: FAILED — $ERRORS issue(s) found on $HOSTNAME"
  logger -t post-patch-check "PATCH HEALTH FAIL: $ERRORS errors on $HOSTNAME — see $LOGFILE"
fi
