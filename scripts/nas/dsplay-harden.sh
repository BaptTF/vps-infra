#!/bin/sh
# dsplay hardening (vps-infra README, "NAS hardening"). Copy to ~Baptiste/bin on dsplay, then run as root:
# ssh -t dsplay 'sudo sh ~/bin/dsplay-harden.sh report|apply'
# report: read-only, writes ~Baptiste/dsplay-harden-report.txt (secrets redacted).
set -u
HOME_B=/var/services/homes/Baptiste
OUT=$HOME_B/dsplay-harden-report.txt

redact() {
	python3 -c '
import json, re, sys
pat = re.compile(r"(psk|secret|pass|token|key|serverid|server_id|cert)", re.I)
def walk(o):
    if isinstance(o, dict):
        return {k: ("***" if pat.search(k) and isinstance(v, (str, int)) and v not in ("", None) else walk(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [walk(x) for x in o]
    return o
raw = sys.stdin.read()
try:
    print(json.dumps(walk(json.loads(raw)), separators=(",", ":"))[:4000])
except Exception:
    print(raw[:2000])
'
}

api() {
	echo "### $*"
	/usr/syno/bin/synowebapi --exec "$@" 2>/dev/null | redact
}

logs() {
	for f in /var/log/auth.log.*.xz; do xz -dc "$f" 2>/dev/null; done
	cat /var/log/auth.log
}

report() {
	echo "## date"; date
	echo "## sshd effective"
	/usr/bin/sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|allowusers|allowgroups) '
	echo "## ssh accepted logins (auth.log, rotated included)"
	logs | grep -oE 'Accepted (password|publickey|keyboard-interactive/pam) for [^ ]+ from [^ ]+' | sort | uniq -c | sort -rn | head -40
	echo "## last 15 accepted"
	logs | grep -E 'sshd.*Accepted' | tail -15 | cut -c1-160
	echo "## failed passwords by user"
	logs | grep -oE 'Failed password for (invalid user )?[^ ]+' | sort | uniq -c | sort -rn | head -15
	echo "## authorized_keys per home"
	for k in /var/services/homes/*/.ssh/authorized_keys; do [ -f "$k" ] && { echo "$k"; awk '{print "  " $1, $NF}' "$k"; }; done
	echo "## users: admin group, expired, 2FA"
	grep -E '^administrators:' /etc/group
	for u in $(awk -F: '$3>=1024 && $3<100000 {print $1}' /etc/passwd); do
		exp=$(synouser --get "$u" 2>/dev/null | grep -i 'Expired' | tr -d ' ')
		otp=no; [ -s "/usr/syno/etc/preference/$u/google_authenticator" ] && otp=yes
		echo "  $u $exp otp=$otp"
	done
	echo "## SMB sessions and shares in use"
	smbstatus -b 2>/dev/null | tail -n +4 | awk '{print $2, $4}' | sort | uniq -c
	smbstatus -S 2>/dev/null | tail -n +4 | awk '{print $1, $3}' | sort | uniq -c
	echo "## NFS exports"; cat /etc/exports 2>&1
	echo "## AFP shares"; grep -E '^\[' /etc/afp.conf 2>&1 | head -30
	echo "## rsyncd modules"; grep -E '^\[' /etc/rsyncd.conf 2>&1 | head
	echo "## Web Station sites"; ls /var/services/web 2>&1 | head; ls /usr/local/etc/nginx/sites-enabled 2>&1 | head
	echo "## WebDAV access (last 10 non-local)"; tail -n 2000 /var/log/webdav/*access* 2>/dev/null | grep -vE '^(127\.|::1)' | tail -10 | cut -c1-160
	echo "## FTP xferlog"; tail -5 /var/log/xferlog 2>&1 | cut -c1-160
	echo "## iSCSI"; ls /usr/syno/etc/iscsi* /usr/syno/etc/lio* 2>&1 | head
	echo "## OpenVPN connected clients"; grep -E '^CLIENT_LIST' /tmp/ovpn_status_2_result 2>/dev/null | cut -d, -f2,3,8 || true
	api api=SYNO.VPNServer.Settings.Config method=load version=1 serv_type=openvpn
	api api=SYNO.VPNServer.Management.Account method=load version=1 start=0 limit=100
	api api=SYNO.VPNServer.Management.Log method=load version=1 start=0 limit=30
	api api=SYNO.Core.QuickConnect method=get version=3
	api api=SYNO.Core.QuickConnect.Upnp method=get version=1
	api api=SYNO.Core.DDNS.Record method=list version=1
	api api=SYNO.Core.OTP.EnforcePolicy method=get version=1
	api api=SYNO.Core.Security.AutoBlock method=get version=1
	api api=SYNO.Core.FileServ.FTP method=get version=3
	api api=SYNO.Core.FileServ.AFP method=get version=2
	api api=SYNO.Core.FileServ.NFS method=get version=3
	api api=SYNO.Core.FileServ.ServiceDiscovery method=get version=1
	api api=SYNO.Core.Terminal method=get version=3
	echo "## packages running"
	for p in WebDAVServer ScsiTarget VPNCenter MediaServer WebStation QuickConnect ProxyServer; do echo "  $p $(/usr/syno/bin/synopkg status "$p" 2>/dev/null | head -c 200)"; done
}

SQUID_ETC=/var/packages/ProxyServer/target/squid/etc
SQUID_LOCAL=$SQUID_ETC/local_hardening.conf
SQUID_INCLUDE="include $SQUID_LOCAL"
STAMP=$(date +%Y%m%d-%H%M%S)

apply_ssh() {
	echo "## ssh: key only"
	cp -p /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$STAMP"
	sed -i -E 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' /etc/ssh/sshd_config
	grep -qE '^PasswordAuthentication no$' /etc/ssh/sshd_config || sed -i '1i PasswordAuthentication no' /etc/ssh/sshd_config
	if /usr/bin/sshd -t; then
		/usr/syno/bin/synosystemctl restart sshd || systemctl restart sshd
		/usr/bin/sshd -T | grep -E '^passwordauthentication '
	else
		echo "sshd -t failed, restoring"; cp -p "/etc/ssh/sshd_config.bak-$STAMP" /etc/ssh/sshd_config
	fi
}

apply_squid() {
	echo "## squid: tailnet clients only, no private destinations"
	cat > "$SQUID_LOCAL" <<'EOF'
# Managed by ~Baptiste/bin/dsplay-harden.sh (vps-infra README, NAS Squid).
# Included before the stock "http_access allow CONNECT SSL_ports", which
# otherwise lets any source tunnel to any host:443.
acl tailnet_clients src 100.64.0.0/10 fd7a:115c:a1e0::/48
acl private_dst dst 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 ::1 fc00::/7 fe80::/10 ff00::/8
http_access deny !tailnet_clients
http_access deny private_dst
EOF
	cp -p "$SQUID_ETC/squid.conf" "$SQUID_ETC/squid.conf.bak-$STAMP"
	if ! grep -qF "$SQUID_INCLUDE" "$SQUID_ETC/squid.conf"; then
		awk -v inc="$SQUID_INCLUDE" '{print} /^include .*acl_syno\.conf$/ {print inc}' "$SQUID_ETC/squid.conf" > "$SQUID_ETC/squid.conf.new" &&
			mv "$SQUID_ETC/squid.conf.new" "$SQUID_ETC/squid.conf"
	fi
	grep -nE 'acl_syno|local_hardening|allow CONNECT' "$SQUID_ETC/squid.conf"
	if /var/packages/ProxyServer/target/bin/squid -k parse -f "$SQUID_ETC/squid.conf" 2>&1 | grep -E 'FATAL|ERROR'; then
		echo "squid parse failed, restoring"; cp -p "$SQUID_ETC/squid.conf.bak-$STAMP" "$SQUID_ETC/squid.conf"; rm -f "$SQUID_LOCAL"
	else
		/var/packages/ProxyServer/target/bin/squid -k reconfigure && echo "squid reconfigured"
	fi
}

apply_quickconnect() {
	echo "## quickconnect, relay, upnp off"
	api api=SYNO.Core.QuickConnect method=set_misc_config version=3 relay_enabled=false
	api api=SYNO.Core.QuickConnect.Upnp method=set version=1 enabled=false
	api api=SYNO.Core.QuickConnect method=set version=1 enabled=false
	api api=SYNO.Core.QuickConnect method=get version=1
	api api=SYNO.Core.QuickConnect method=get_misc_config version=3
	api api=SYNO.Core.QuickConnect.Upnp method=get version=1
}

apply_services() {
	echo "## ftp, webdav, iscsi, tailscale web client off"
	api api=SYNO.Core.FileServ.FTP method=set version=3 enable_ftp=false enable_ftps=false
	api api=SYNO.Core.FileServ.FTP method=get version=3
	/usr/syno/bin/synopkg stop WebDAVServer
	/usr/syno/bin/synopkg stop ScsiTarget
	/var/packages/Tailscale/target/bin/tailscale set --webclient=false && echo "tailscale webclient off"
	for p in WebDAVServer ScsiTarget; do echo "  $p: $(/usr/syno/bin/synopkg status "$p" 2>&1 | head -c 200)"; done
}

case "${1:-}" in
	report) report > "$OUT" 2>&1; chown Baptiste:users "$OUT"; chmod 600 "$OUT"; echo "written $OUT" ;;
	apply)
		LOG=$HOME_B/dsplay-harden-apply.txt
		{ date; apply_squid; apply_ssh; apply_quickconnect; apply_services; } > "$LOG" 2>&1
		chown Baptiste:users "$LOG"; chmod 600 "$LOG"; echo "written $LOG" ;;
	*) echo "usage: $0 report|apply" >&2; exit 2 ;;
esac
