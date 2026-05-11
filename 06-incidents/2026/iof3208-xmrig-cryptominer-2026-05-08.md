# Incident: XMRig Monero Cryptominer — iof3208 (107.178.113.26)
**Date:** 2026-05-08  
**Server:** iof3208, 107.178.113.26, port 1022, Ubuntu 24.04.3 LTS  
**Severity:** Critical — load average peaked at 38+, all services degraded  
**Duration:** ~12 hours (breach ~20:32 UTC May 7 → cleaned ~05:27 UTC May 8)

---

## Root Cause

SSH password brute-force on `udc` user. No fail2ban, password auth enabled globally, weak/reused password.

**Attacker IPs (in order of appearance):**
- `157.49.114.182` — initial breach, May 7 20:32 UTC
- `103.253.174.226` — continued, May 8 01:05 UTC
- `152.58.123.176` — latest session, May 8 05:10 UTC (verify if attacker or legit)

---

## Attack Anatomy

```
Attacker SSH login → install XMRig as udc user → inject crontab persistence →
guard.sh contacts C2 every 30 min → self-heals if binary deleted
```

### Malware Files
| Path | Purpose |
|------|---------|
| `/home/udc/.local/share/systemd-networkd/let` | Miner binary (disguised as systemd) |
| `/home/udc/.local/share/.backup1/guard.sh` | Guardian/watchdog script |
| `/home/udc/.local/share/.backup1/let` | Backup miner binary |
| `/home/udc/.local/share/.backup2/` | Second backup (same structure) |
| `/home/udc/.local/share/systemd-networkd/config.json` | XMRig config |
| `/home/udc/udc_master_website/.track/npm` | Original binary (deleted while running) |
| `/home/udc/.syslog-6dec5467/` | Staging/lock directory |

### Disguise Technique
- Miner process name: `next-server (v15.5.6)` — matches legitimate Next.js processes on same server
- Binary deleted from disk after launch → shows as `(deleted)` in `/proc/<PID>/exe`
- Watchdog named `bash syslog-helper` — looks like system process

### Persistence Mechanism
```cron
@reboot sh -c 'cd /home/udc/.local/share/systemd-networkd && .../let' >/dev/null 2>&1 &
*/30 * * * * sh -c '[...] .backup1/guard.sh || .backup2/guard.sh'
```

`guard.sh` actions every 30 minutes:
1. Restore `let` binary from backup if missing
2. Install systemd service `systemd-networkd-helper` if not present
3. Fetch and execute remote commands from `http://d.monero1478.com/download/linux.txt`
4. Re-add crontab if removed

### C2 & Mining Pool
- **C2:** `http://d.monero1478.com/download/linux.txt` (remote shell execution)
- **Mining pool:** `auto.c3pool.org:33333` (TLS) and `:19999`
- **Wallet (XMR):** `83GoGaLvBLAJXHXfg9sBfpWNXufV3hi4dBrbHUCmoC8naHHgPfmyYrAB4kqRu7Kx51h3mXCJr81Ty8AnyJvnmpw5R3fn6cT`
- **Pool connection IP:** `107.167.83.34:443`

### Lateral Spread
Same malware installed on **6 additional users** on the same server (same password auth vector):
- `atb-erp`, `atb-vendor-erp`, `capacitor`, `erp-demo`, `utsav-erp`, `utsav_new`

---

## Remediation Steps Taken

```bash
# 1. Remove malicious crontab (all affected users)
crontab -u <user> -r

# 2. Kill watchdog and miner processes
kill -9 <syslog-helper PIDs>
kill -9 <miner PIDs>

# 3. Remove all malware directories
rm -rf /home/<user>/.local/share/systemd-networkd/
rm -rf /home/<user>/.local/share/.backup1/
rm -rf /home/<user>/.local/share/.backup2/
rm -rf /home/<user>/.syslog-*/
find /home/<user> -name '.track' -type d -exec rm -rf {} +

# 4. Block C2 and mining pools
iptables -A OUTPUT -d 107.167.83.34 -j DROP
iptables -A OUTPUT -p tcp --dport 33333 -j DROP
iptables -A OUTPUT -p tcp --dport 19999 -j DROP
iptables -A INPUT -s 157.49.114.182 -j DROP
iptables -A INPUT -s 103.253.174.226 -j DROP
netfilter-persistent save

# 5. Block C2 domain at DNS level
echo '0.0.0.0 d.monero1478.com' >> /etc/hosts
echo '0.0.0.0 monero1478.com' >> /etc/hosts

# 6. Disable SSH password auth
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sshd -t && systemctl reload sshd

# 7. Lock all compromised user passwords
passwd -l <user>

# 8. Restore legitimate bench backup crontabs (were wiped with malicious ones)
echo '0 */6 * * * cd /home/<user>/frappe-bench && bench backup ...' | crontab -u <user> -
```

### Verification Commands
```bash
pgrep -u <user> -f 'syslog-helper|systemd-networkd/let'  # should return nothing
find /home -path '*/.local/share/.backup*' -type d        # should return nothing
crontab -u <user> -l | grep -E 'guard|backup[12]'        # should return nothing
uptime                                                     # load should normalize within 5 min
```

---

## Post-Incident Actions Required (Manual)

- [ ] Kill or verify active session from `152.58.123.176` on `udc` pts/11 (sshd PID 1466881)
- [ ] Set up SSH key-based auth for all application users (key in `~/.ssh/authorized_keys`)
- [ ] Rotate all SSH keys (attacker had shell access — keys may be compromised)
- [ ] Install and configure fail2ban for SSH
- [ ] Audit what data attacker accessed during 12-hour window (check bash histories)
- [ ] Consider whether ERP/app data was exfiltrated
- [ ] Enable `UsePAM no` or per-user key enforcement in sshd_config

---

## Detection Indicators

| IOC Type | Value |
|----------|-------|
| Process name | `next-server (v15.5.x)` with deleted exe path |
| Process name | `bash syslog-helper` |
| Cron pattern | `*/30 * * * * ... .backup1/guard.sh` |
| Cron pattern | `@reboot ... systemd-networkd/let` |
| Directory | `.local/share/systemd-networkd/` in home dir |
| Directory | `.local/share/.backup1/` or `.backup2/` |
| Domain | `monero1478.com`, `c3pool.org` |
| Port outbound | 33333, 19999 (Monero mining) |
| IP | `107.167.83.34` (mining pool) |

---

## Cross-Client Learning

This pattern can appear on **any server with SSH password auth enabled and multiple system users**.  
Check all clients with shared application servers for the same IOCs. Particularly relevant for:
- Any server running Frappe/ERPNext with per-client Linux users
- Servers where application users have SSH access with password auth
