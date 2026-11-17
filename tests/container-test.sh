#!/usr/bin/env bash
# End-to-end test of the kit against a throwaway Ubuntu or Debian container (podman). Touches no real server.
# Needs: podman, ansible-playbook on PATH, and the collections from requirements.yml.
# Run from the kit folder: bash tests/container-test.sh
# A container shares your kernel, so kernel settings are skipped here (verify.yml --skip-tags kernel).
set -uo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
cp_dir=$(mktemp -d /tmp/hk.XXXX)   # short path: SSH control sockets must stay under 108 bytes
name=hardening-test-$$
port=${TEST_PORT:-2222}
# Base image, pinned by digest. CI runs Ubuntu 24.04, Ubuntu 26.04 and Debian 13.
image=${TEST_IMAGE:-docker.io/library/ubuntu@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8}
fails=0
cleanup() { podman rm -f -t 0 "$name" >/dev/null 2>&1; podman rmi -f "localhost/$name" >/dev/null 2>&1; rm -rf "$work" "$cp_dir"; }
trap cleanup EXIT

export ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_CONTROL_PATH_DIR=$cp_dir ANSIBLE_NOCOLOR=1
ssh_test=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)

ssh-keygen -q -t ed25519 -N '' -f "$work/key"
ssh-keygen -q -t ed25519 -N '' -f "$work/wrongkey"
cat > "$work/Containerfile" <<CF
FROM $image
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y systemd systemd-sysv openssh-server sudo python3 iptables ufw netcat-openbsd \
 && useradd -m -s /bin/bash deploy && echo 'deploy:container-only-password' | chpasswd \
 && echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy && mkdir -p /home/deploy/.ssh \
 && printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf \
 && sed -i 's/^#Port 22/Port $port/' /etc/ssh/sshd_config
COPY key.pub /home/deploy/.ssh/authorized_keys
RUN chown -R deploy:deploy /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
CMD ["/sbin/init"]
CF
echo "== Building the test image"
podman build -q -t "localhost/$name" "$work" >/dev/null || { echo "image build failed"; exit 1; }

inv=$work/inv.ini
printf '[servers]\nct ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s\n[servers:vars]\nopen_ports=[]\nansible_ssh_common_args="-o UserKnownHostsFile=%s"\n' "$port" "$work/key" "$work/known_hosts" > "$inv"
# Ansible logs in with the right key (extra_args are Ansible-only); the kit's guard gets one the server does not trust.
inv_wrong=$work/inv-wrong.ini
printf '[servers]\nct ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s ansible_ssh_extra_args="-i %s -o IdentitiesOnly=yes" ansible_ssh_common_args="-o UserKnownHostsFile=%s"\n' "$port" "$work/wrongkey" "$work/key" "$work/known_hosts" > "$inv_wrong"

fresh() {
  podman rm -f -t 0 "$name" >/dev/null 2>&1; rm -f "$work/known_hosts"
  podman run -d --name "$name" --privileged --systemd=always -p "127.0.0.1:$port:$port" "localhost/$name" >/dev/null
  # Keep the distro's own SSH layout (socket activation on Ubuntu): wait until the port answers.
  for _ in $(seq 150); do ssh-keyscan -p "$port" 127.0.0.1 2>/dev/null | grep -q . && return; sleep 0.2; done
  echo "container did not start sshd"; exit 1
}
state() { podman exec "$name" sh -c 'echo "$(sshd -T | grep ^passwordauthentication) | drop-ins: $(ls /etc/ssh/sshd_config.d | tr "\n" " ")"'; }
# Never apply kernel settings here: a container shares this machine's kernel.
play() { (cd "$kit" && ansible-playbook --skip-tags kernel "$@") > "$work/last.log" 2>&1; }
check() { # check <description> <command...>
  if "${@:2}"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); tail -n 25 "$work/last.log"; fi
}
password_on() { state | grep -q 'passwordauthentication yes'; }
no_dropin() { ! podman exec "$name" test -e /etc/ssh/sshd_config.d/00-hardening.conf; }
not() { ! "$@"; }
untouched() { password_on && no_dropin; }
no_changes() { play -i "$inv" harden.yml --check && grep -q "changed=0" "$work/last.log"; }
key_login() { ssh "${ssh_test[@]}" -o BatchMode=yes -o ControlPath=none -i "$work/key" -p "$port" deploy@127.0.0.1 true; }

echo "== 1. Fresh server"
fresh; echo "      $(state)"
check "verify fails on an unhardened server" not play -i "$inv" verify.yml
check "dry run succeeds" play -i "$inv" harden.yml --check --diff
check "dry run left password login and SSH files alone" untouched
echo "      $(state)"

echo "== 2. Apply"
check "harden succeeds" play -i "$inv" harden.yml
echo "      $(state)"
check "second dry run reports no changes" no_changes
check "verify passes (kernel skipped in a container)" play -i "$inv" verify.yml
check "key login still works on port $port" key_login

echo "== 3. Lockout guard: an untrusted key"
fresh
check "harden stops" not play -i "$inv_wrong" harden.yml
check "password login untouched, no drop-in written" untouched
echo "      $(state)"

echo "== 4. Undo: main sshd_config forces passwords before the drop-in is read"
fresh
podman exec "$name" sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
check "harden stops" not play -i "$inv" harden.yml
check "drop-in removed again" no_dropin
check "key login still works" key_login
echo "      $(state)"

echo "== 5. Rerun after something overrides the drop-in"
fresh
check "harden succeeds" play -i "$inv" harden.yml
podman exec "$name" sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
check "rerun stops and says SSH is not hardened" not play -i "$inv" harden.yml
check "the message names the cause" grep -q "SSH is not hardened" "$work/last.log"
echo "      $(state)"

echo "== 6. ufw is off but holds a deny rule for the SSH port"
fresh
podman exec "$name" ufw deny "$port/tcp" >/dev/null
check "harden stops" not play -i "$inv" harden.yml
check "ufw is still off" bash -c "podman exec $name ufw status | grep -q 'Status: inactive'"
check "key login still works" key_login

echo "== 7. Your ssh options point at a live connection socket"
fresh
ssh "${ssh_test[@]}" -fN -o ControlMaster=yes -o ControlPath="$work/cm" -i "$work/key" -p "$port" deploy@127.0.0.1
inv_sock=$work/inv-sock.ini
printf '[servers]\nct ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s ansible_ssh_extra_args="-i %s -o IdentitiesOnly=yes" ansible_ssh_common_args="-o UserKnownHostsFile=%s -o ControlPath=%s"\n' "$port" "$work/wrongkey" "$work/key" "$work/known_hosts" "$work/cm" > "$inv_sock"
check "guard makes a fresh login and stops (-o ControlPath)" not play -i "$inv_sock" harden.yml
sed -i "s|-o ControlPath=$work/cm|-S $work/cm|" "$inv_sock"
check "guard makes a fresh login and stops (-S)" not play -i "$inv_sock" harden.yml
check "password login untouched, no drop-in written" untouched
ssh -O exit -o ControlPath="$work/cm" deploy@127.0.0.1 2>/dev/null

echo "== 8. Tunnel-only SSH without a tunnel"
fresh
check "harden refuses ssh_public=false when this run has no tunnel" not play -i "$inv" harden.yml -e ssh_public=false
check "nothing changed" untouched

check "harden refuses ProxyCommand=none" not play -i "$inv" harden.yml -e ssh_public=false -e "ansible_ssh_common_args='-o UserKnownHostsFile=$work/known_hosts -o ProxyCommand=none'"

echo "== 8b. Tunnel-only SSH through a tunnel that ends on the server's loopback"
fresh
inv_tun=$work/inv-tunnel.ini
printf '[servers]\nct ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s ssh_public=false ansible_ssh_common_args='"'"'-o UserKnownHostsFile=%s -o ProxyCommand="podman exec -i %s nc 127.0.0.1 %s"'"'"'\n[servers:vars]\nopen_ports=[]\n' "$port" "$work/key" "$work/known_hosts" "$name" "$port" > "$inv_tun"
check "harden succeeds with the SSH port closed" play -i "$inv_tun" harden.yml
check "ufw has no rule for the SSH port" bash -c "! podman exec $name ufw status | grep -q '^$port/tcp'"
check "verify passes through the tunnel" play -i "$inv_tun" verify.yml

echo "== 8d. Tunnel-only SSH through a tunnel that reaches sshd from a non-loopback address"
fresh
inv_far=$work/inv-far.ini
# The tunnel ends on the container's own network address, so sshd sees a non-loopback client.
podman exec "$name" sh -c 'printf "#!/bin/sh\nexec nc \"\$(hostname -I | cut -d\" \" -f1)\" \"\$1\"\n" > /usr/local/bin/far-nc && chmod +x /usr/local/bin/far-nc'
sed "s|nc 127.0.0.1 $port|far-nc $port|" "$inv_tun" > "$inv_far"
check "harden refuses: the firewall would block this path" not play -i "$inv_far" harden.yml
check "for that reason" grep -q "not loopback" "$work/last.log"
check "nothing changed" untouched

echo "== 8c. AllowUsers is exactly the expected list"
fresh
podman exec "$name" useradd -m ops
check "harden succeeds with two allowed users" play -i "$inv" harden.yml -e '{"ssh_allow_users": ["deploy", "ops"]}'
check "verify passes with the same list" play -i "$inv" verify.yml -e '{"ssh_allow_users": ["deploy", "ops"]}'
podman exec "$name" sh -c 'getent group docker >/dev/null || groupadd docker'
podman exec "$name" usermod -aG docker ops
check "verify rejects a second allowed user in the docker group" not play -i "$inv" verify.yml -e '{"ssh_allow_users": ["deploy", "ops"]}'
check "the failure names the second user" grep -q "ops is in the docker group" "$work/last.log"
podman exec "$name" gpasswd -d ops docker
check "verify passes after group membership is removed" play -i "$inv" verify.yml -e '{"ssh_allow_users": ["deploy", "ops"]}'
check "verify fails against the default list" not play -i "$inv" verify.yml
fresh
check "harden succeeds" play -i "$inv" harden.yml
podman exec "$name" sh -c 'echo "AllowUsers intruder" > /etc/ssh/sshd_config.d/99-extra.conf'
check "verify fails when another file adds an account" not play -i "$inv" verify.yml
check "rerun stops on it too" not play -i "$inv" harden.yml
podman exec "$name" sh -c 'echo "AllowUsers *" > /etc/ssh/sshd_config.d/99-extra.conf'
check "verify fails on an AllowUsers wildcard" not play -i "$inv" verify.yml

echo "== 9. Undo keeps a drop-in that existed before the run"
fresh
check "harden succeeds" play -i "$inv" harden.yml
podman exec "$name" chmod 0644 /etc/ssh/sshd_config.d/00-hardening.conf
podman exec "$name" sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
check "rerun stops" not play -i "$inv" harden.yml
check "the existing drop-in is still there" not no_dropin

echo "== 10. verify catches broken updates and an unreachable Docker"
fresh
check "harden succeeds" play -i "$inv" harden.yml
check "verify passes" play -i "$inv" verify.yml
podman exec "$name" sh -c 'printf "#clear Unattended-Upgrade::Allowed-Origins;\n#clear Unattended-Upgrade::Origins-Pattern;\n" > /etc/apt/apt.conf.d/99-test-clear'
check "verify fails when a later file clears the security origins" not play -i "$inv" verify.yml
check "for that reason" grep -q "No effective unattended-upgrades origin" "$work/last.log"
podman exec "$name" rm /etc/apt/apt.conf.d/99-test-clear
podman exec "$name" sh -c 'printf "#!/bin/sh\necho cannot connect >&2\nexit 1\n" > /usr/bin/docker && chmod +x /usr/bin/docker'
check "verify fails when Docker can't be asked" not play -i "$inv" verify.yml
check "for that reason" bash -c 'grep -A4 "List every host port" "$0" | grep -q "^fatal"' "$work/last.log"

echo "== 11. The login after turning ufw on fails: ufw goes back off"
# Container traffic arrives on loopback, which ufw always accepts, so a proxy stands in for the blocked path:
# it refuses new logins once ufw holds the kit's LIMIT rule for SSH.
cat > "$work/firewall-proxy" <<PROXY
#!/usr/bin/env bash
if podman exec "$name" ufw status | grep -q LIMIT; then
  exit 1
fi
exec podman exec -i "$name" nc 127.0.0.1 "$port"
PROXY
chmod +x "$work/firewall-proxy"
inv_fw=$work/inv-firewall.ini
printf '[servers]\nct ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s ansible_ssh_common_args='"'"'-o UserKnownHostsFile=%s -o ProxyCommand="%s"'"'"'\n[servers:vars]\nopen_ports=[]\n' "$port" "$work/key" "$work/known_hosts" "$work/firewall-proxy" > "$inv_fw"
fresh
check "harden stops" not play -i "$inv_fw" harden.yml
check "for that reason" grep -q "firewall change or the new SSH login after it failed" "$work/last.log"
check "ufw is off again" bash -c "podman exec $name ufw status | grep -q 'Status: inactive'"
check "key login still works" key_login
check "no SSH drop-in written" no_dropin

echo "== 11b. The login after changing an active firewall fails: ufw stays on"
fresh
podman exec "$name" ufw allow "$port/tcp" >/dev/null
podman exec "$name" ufw --force enable >/dev/null
check "harden stops" not play -i "$inv_fw" harden.yml
check "for that reason" grep -q "firewall change or the new SSH login after it failed" "$work/last.log"
check "ufw is still on" bash -c "podman exec $name ufw status | grep -q 'Status: active'"
check "no SSH drop-in written" no_dropin
check "key login still works without the proxy" key_login

echo "== 12. Docker installed without apt"
fresh
podman exec "$name" sh -c 'printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/dockerd && chmod +x /usr/local/bin/dockerd'
check "harden succeeds with a static dockerd and no /etc/docker" play -i "$inv" harden.yml
check "daemon.json written" podman exec "$name" test -s /etc/docker/daemon.json
podman exec "$name" chmod 0700 /etc/docker
check "harden succeeds with an existing /etc/docker" play -i "$inv" harden.yml
check "existing /etc/docker stays 0700" podman exec "$name" sh -c '[ "$(stat -c %a /etc/docker)" = 700 ]'
podman exec "$name" sh -c 'printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/docker && chmod +x /usr/local/bin/docker && printf "[Service]\nExecStart=/bin/true\n" > /etc/systemd/system/docker.service && systemctl daemon-reload && touch -d "2000-01-01" /etc/docker/daemon.json'
check "Docker has no start time" podman exec "$name" sh -c 'started=$(systemctl show -p ActiveEnterTimestamp --value docker) && [ -z "$started" ]'
check "verify fails without a Docker start time" not play -i "$inv" verify.yml
check "for that reason" bash -c 'grep -A4 "Docker has been restarted since daemon.json changed" "$0" | grep -q "^fatal"' "$work/last.log"
fresh
podman exec "$name" mkdir -p /snap/docker
check "harden succeeds and skips snap Docker without a dockerd alias" play -i "$inv" harden.yml
check "it says snap Docker is not supported" grep -q "Docker from snap" "$work/last.log"
check "no /etc/docker written" not podman exec "$name" test -e /etc/docker/daemon.json
check "verify refuses snap Docker without a dockerd alias" not play -i "$inv" verify.yml
check "for that reason" grep -q "Snap Docker is not supported; use Docker's apt packages or a static install" "$work/last.log"
podman exec "$name" sh -c 'mkdir -p /etc/docker && printf "%s\n" "{\"no-new-privileges\": true, \"log-opts\": {\"max-size\": \"10m\"}}" > /etc/docker/daemon.json && touch -d "2000-01-01" /etc/docker/daemon.json && printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/docker && chmod +x /usr/local/bin/docker'
check "harden still skips snap Docker with a stale daemon.json" play -i "$inv" harden.yml
check "it says snap Docker is not supported" grep -q "Docker from snap" "$work/last.log"
check "verify still refuses snap Docker with a stale daemon.json" not play -i "$inv" verify.yml
check "for that reason" grep -q "Snap Docker is not supported; use Docker's apt packages or a static install" "$work/last.log"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; fi
exit "$fails"
