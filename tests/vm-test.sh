#!/usr/bin/env bash
# Full test of the kit against a throwaway Ubuntu 24.04/26.04 or Debian 13 VM (QEMU/KVM). Unlike the
# container test, the kernel settings and a real Docker daemon run here. Touches no real server.
# Debian skips the two apport regression cases.
# Both run hardening, idempotence, Docker, login, reboot, ufw, forwarding, group and repository checks.
# VM_IMAGE: ubuntu-26.04 (default), ubuntu-24.04 or debian-13.
# Needs: qemu-system-x86_64, qemu-img, /dev/kvm, python3, curl, ssh. Run from the kit folder:
#   bash tests/vm-test.sh          # build, test, delete the VM
#   bash tests/vm-test.sh --keep   # leave the VM running afterwards (ssh command printed at the end)
set -uo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
work=${VM_WORK:-$HOME/.cache/hardening-vm}
port=${VM_PORT:-2230}
seed_port=$((port + 6500))
[ "$seed_port" -le 65535 ] || { echo "VM_PORT is too high for its seed HTTP port"; exit 1; }
keep=${1:-}
image=${VM_IMAGE:-ubuntu-26.04}
case "$image" in
  ubuntu-26.04|ubuntu-24.04)
    img_dir=https://cloud-images.ubuntu.com/releases/${image#ubuntu-}/release
    img_name=$image-server-cloudimg-amd64.img
    sums=SHA256SUMS; sum_cmd=sha256sum
    ssh_units='ssh.socket, ssh.service'
    ;;
  debian-13)
    img_dir=https://cloud.debian.org/images/cloud/trixie/latest
    img_name=debian-13-genericcloud-amd64.qcow2
    sums=SHA512SUMS; sum_cmd=sha512sum
    ssh_units=ssh.service
    ;;
  *) echo "Unknown VM_IMAGE: $image (use ubuntu-26.04, ubuntu-24.04 or debian-13)"; exit 1 ;;
esac
# shortcut: checks published checksums over HTTPS but not their GPG signatures; add gpgv if this ever leaves test use.
# Keep the default cache path; other images get their own base, disk and running-VM state.
[ "$image" = ubuntu-26.04 ] || work=$work/$image
fails=0; passes=0; skips=0

need() { command -v "$1" >/dev/null || { echo "Missing: $1"; missing=1; }; }
missing=0
for c in qemu-system-x86_64 qemu-img python3 curl ssh ssh-keygen "$sum_cmd"; do need "$c"; done
[ -w /dev/kvm ] || { echo "Missing: write access to /dev/kvm (is virtualization on in the BIOS, and are you in the kvm group?)"; missing=1; }
if [ "$missing" = 1 ]; then
  echo; echo "Install with:  sudo dnf install qemu-kvm-core qemu-img (Fedora)  or  sudo apt install qemu-system-x86 qemu-utils python3-venv (Ubuntu, Debian)"; exit 1
fi

python3 -c 'import sys; sys.exit(sys.version_info < (3, 13))' || {
  echo "The controller needs Python 3.13 or newer for ansible-core 2.22; select a newer python3 before running this test."
  exit 1
}

mkdir -p "$work"
exec 9>"$work/lock"; flock -n 9 || { echo "Another vm-test.sh is using $work"; exit 1; }
if [ -f "$work/qemu.pid" ] && kill -0 "$(cat "$work/qemu.pid")" 2>/dev/null; then
  echo "A VM kept by an earlier --keep run is still running; stop it first: kill $(cat "$work/qemu.pid") $(cat "$work/http.pid" 2>/dev/null)"; exit 1
fi
cp_dir=$(mktemp -d /tmp/hv.XXXX)   # short path: SSH control sockets must stay under 108 bytes
qemu_pid=; http_pid=
cleanup() {
  # a kept VM keeps its seed server, so it can still reboot without new host keys
  if [ "$keep" = "--keep" ] && [ -n "$qemu_pid" ]; then rm -rf "$cp_dir"; return; fi
  [ -n "$http_pid" ] && kill "$http_pid" 2>/dev/null
  if [ -n "$qemu_pid" ]; then kill "$qemu_pid" 2>/dev/null; rm -f "$work/disk.qcow2" "$work/qemu.pid" "$work/http.pid"; fi
  rm -rf "$cp_dir"
}
trap cleanup EXIT

echo "== Ansible tools (pinned, in $work/venv)"
if [ ! -x "$work/venv/bin/ansible-playbook" ]; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q -r "$kit/requirements-controller.txt" || exit 1
fi
# Point galaxy at this image's folder, or it skips the install when the collection exists on an inherited path.
ANSIBLE_COLLECTIONS_PATH=$work/coll "$work/venv/bin/ansible-galaxy" collection install -r "$kit/requirements.yml" -p "$work/coll" >/dev/null || exit 1
export PATH="$work/venv/bin:$PATH" ANSIBLE_COLLECTIONS_PATH=$work/coll ANSIBLE_SSH_CONTROL_PATH_DIR=$cp_dir ANSIBLE_NOCOLOR=1

echo "== $image cloud image"
cd "$work" || exit 1
curl -fsSL -o "$sums" "$img_dir/$sums" || { echo "Could not fetch $sums"; exit 1; }
# Match the filename literally, including checksum lists that prefix it with ./ or *.
awk -v name="$img_name" '{file=$2; sub(/^\*/, "", file); sub(/^\.\//, "", file); if (file == name) print $1 "  " name}' "$sums" > image.checksum
[ "$(wc -l < image.checksum)" -eq 1 ] || { echo "Expected one checksum for $img_name in $sums"; exit 1; }
if ! "$sum_cmd" -c --status image.checksum 2>/dev/null; then
  curl -fL -o "$img_name" "$img_dir/$img_name" || exit 1
  "$sum_cmd" -c image.checksum || { echo "Checksum mismatch; deleting the image"; rm -f "$img_name"; exit 1; }
fi

echo "== Test key and cloud-init"
[ -f key ] || ssh-keygen -q -t ed25519 -N '' -f key -C hardening-vm-test
mkdir -p seed
# Ubuntu and Debian cloud images use Netplan; the lab card gets DHCP without a default route.
lab_files=; lab_cmd=; lab_net=()
if [ -n "${VM_LAB_TAP:-}" ]; then
  lab_files="  - path: /etc/netplan/60-lab.yaml
    permissions: '0600'
    content: '{network: {version: 2, ethernets: {lab0: {match: {macaddress: \"$VM_LAB_MAC\"}, set-name: lab0, dhcp4: true, dhcp4-overrides: {use-routes: false}}}}}'"
  lab_cmd="  - [netplan, apply]"
  lab_net=(-netdev tap,id=lan,fd=3 -device "virtio-net-pci,netdev=lan,mac=$VM_LAB_MAC")
fi
printf 'instance-id: hardening-vm-%s\nlocal-hostname: hardening-vm\n' "$(date +%s)" > seed/meta-data
cat > seed/user-data <<EOF
#cloud-config
users:
  - name: deploy
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [$(cat key.pub)]
ssh_pwauth: true
package_update: true
packages: [docker.io]
# The kit checks that sshd lists the port Ansible uses, so sshd listens on the forwarded port itself.
write_files:
  - path: /etc/ssh/sshd_config.d/10-test-port.conf
    content: "Port $port\n"
$lab_files
runcmd:
$lab_cmd
  - [systemctl, daemon-reload]
  - [systemctl, restart, $ssh_units]
EOF
: > seed/vendor-data
python3 -m http.server "$seed_port" --bind 127.0.0.1 --directory seed >/dev/null 2>&1 & http_pid=$!
echo "$http_pid" > http.pid
seed_ready=false
for _ in $(seq 20); do
  kill -0 "$http_pid" 2>/dev/null || break
  if curl -fsS "http://127.0.0.1:$seed_port/meta-data" >/dev/null; then seed_ready=true; break; fi
  sleep 0.1
done
if ! kill -0 "$http_pid" 2>/dev/null || [ "$seed_ready" != true ]; then
  echo "Seed HTTP server failed to start or answer on 127.0.0.1:$seed_port; check for a port conflict."
  exit 1
fi

echo "== Starting the VM (SSH on 127.0.0.1:$port)"
rm -f disk.qcow2 known_hosts
qemu-img create -q -f qcow2 -F qcow2 -b "$work/$img_name" disk.qcow2 12G
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -display none -serial file:console.log -daemonize -pidfile qemu.pid \
  -drive file=disk.qcow2,if=virtio -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$seed_port/" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:$port" -device virtio-net-pci,netdev=n0 \
  "${lab_net[@]}" 3<>"${VM_LAB_TAP:-/dev/null}" || exit 1
qemu_pid=$(cat qemu.pid)

ssh_vm=(ssh -o UserKnownHostsFile="$work/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes
        -o ConnectTimeout=5 -o ControlMaster=auto -o ControlPath="$cp_dir/vm" -o ControlPersist=120 -i "$work/key" -p "$port" deploy@127.0.0.1)
wait_vm() {  # optional arg: seconds between tries
  for _ in $(seq $((600 / ${1:-5}))); do "${ssh_vm[@]}" true 2>/dev/null && return 0; sleep "${1:-5}"; done
  echo "The VM did not answer on SSH"; exit 1
}
wait_vm
echo "      waiting for cloud-init (installs Docker) ..."
"${ssh_vm[@]}" 'cloud-init status --wait >/dev/null; cloud-init status' || true
# keep the seed server up: on a reboot cloud-init reads it again, and without it makes new SSH host keys
if "${ssh_vm[@]}" test -e /var/run/reboot-required; then
  echo "      rebooting once for pending updates"; "${ssh_vm[@]}" sudo systemctl reboot 2>/dev/null; sleep 10; wait_vm
fi

inv=$work/inv.ini
printf '[servers]\nvm ansible_host=127.0.0.1 ansible_port=%s ansible_user=deploy ansible_ssh_private_key_file=%s\n[servers:vars]\nopen_ports=[]\nansible_ssh_common_args="-o UserKnownHostsFile=%s"\n' \
  "$port" "$work/key" "$work/known_hosts" > "$inv"
play() { (cd "$kit" && ansible-playbook -i "$inv" "$@") > "$work/last.log" 2>&1; }
check() { if "${@:2}"; then echo "PASS  $1"; passes=$((passes + 1)); else echo "FAIL  $1"; fails=$((fails + 1)); tail -n 30 "$work/last.log"; fi; }
skip() { echo "SKIP  $1 (Debian has no apport)"; skips=$((skips + 1)); }
not() { ! "$@"; }

echo "== Kit, kernel settings and Docker included"
check "verify fails before hardening" not play verify.yml
"${ssh_vm[@]}" "echo 'fs.protected_fifos = 1' | sudo tee /etc/sysctl.d/90-hardening.conf >/dev/null"
check "dry run succeeds" play harden.yml --check --diff
check "harden succeeds" play harden.yml
check "legacy sysctl file is removed and the last hardening file exists" "${ssh_vm[@]}" 'sudo test ! -e /etc/sysctl.d/90-hardening.conf && sudo test -f /etc/sysctl.d/99-zz-hardening.conf'
no_changes() { play harden.yml --check && grep -q "changed=0" "$work/last.log"; }
check "second dry run reports no changes" no_changes
check "verify fails until Docker is restarted" not play verify.yml
restart_reason() { grep -A3 "Docker has been restarted since daemon.json changed" "$work/last.log" | grep -q "^fatal"; }
check "for that reason" restart_reason
"${ssh_vm[@]}" sudo systemctl restart docker
check "verify passes, kernel settings included" play verify.yml
check "sysctl --system keeps FIFO protection at 2" "${ssh_vm[@]}" 'sudo sysctl --system >/dev/null && test "$(sudo sysctl -n fs.protected_fifos)" = 2'
check "Docker runs with no-new-privileges" "${ssh_vm[@]}" 'sudo docker info --format "{{.SecurityOptions}}" | grep -q no-new-privileges'
check "key login still works" "${ssh_vm[@]}" true
# ufw now rate-limits SSH (6 new connections in 30 s blocks the address), so retry slowly
# One shared SSH connection keeps the test under ufw's limit; wait out the 30 s window before rebooting.
boot_id() { "${ssh_vm[@]}" cat /proc/sys/kernel/random/boot_id; }
sleep 35; before=$(boot_id); "${ssh_vm[@]}" sudo systemctl reboot
"${ssh_vm[@]}" -O exit 2>/dev/null; sleep 30; wait_vm 20
after=$(boot_id)
rebooted() { [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; }
check "the VM really rebooted (new boot ID)" rebooted
check "after a reboot, verify still passes (nothing resets the kernel settings)" play verify.yml

# verify must also catch a setting that would only bite at the next boot. Each case is undone afterwards.
# Each verify run makes a refused password login; back to back, ufw limit and OpenSSH's PerSourcePenalties
# start dropping new connections, so let both cool down before every run.
cool() { "${ssh_vm[@]}" -O exit 2>/dev/null; sleep 60; }
boot_reset_caught() {  # $1: command that breaks it, $2: command that undoes it, $3: text verify must report
  cool; "${ssh_vm[@]}" "$1" || return 1
  ! play verify.yml "${@:4}"; local failed=$?
  "${ssh_vm[@]}" "$2"
  [ "$failed" -eq 0 ] && grep -q "$3" "$work/last.log"
}
check "verify fails when a later line turns ufw's sysctl file back on" boot_reset_caught \
  "echo 'IPT_SYSCTL=/etc/ufw/sysctl.conf' | sudo tee -a /etc/default/ufw >/dev/null" \
  "sudo sed -i '\$d' /etc/default/ufw" "ufw still applies its own sysctl file"
if [ "$image" = debian-13 ]; then
  skip "verify fails when a later line turns apport back on"
else
  check "verify fails when a later line turns apport back on" boot_reset_caught \
    "echo 'enabled=1' | sudo tee -a /etc/default/apport >/dev/null" \
    "sudo sed -i '\$d' /etc/default/apport" "apport is enabled=1"
fi
check "verify fails when /etc/default/ufw cannot be read as shell" boot_reset_caught \
  "echo 'if true; then' | sudo tee -a /etc/default/ufw >/dev/null" \
  "sudo sed -i '\$d' /etc/default/ufw" "cannot read /etc/default/ufw"
if [ "$image" = debian-13 ]; then
  skip "verify fails when the apport service is enabled"
else
  check "verify fails when the apport service is enabled" boot_reset_caught \
    "sudo systemctl enable --quiet apport.service" \
    "sudo systemctl disable --quiet apport.service" "apport.service is enabled"
fi
check "verify fails when agent forwarding is allowed" boot_reset_caught \
  "sudo sed -i 's/^AllowAgentForwarding no/AllowAgentForwarding yes/' /etc/ssh/sshd_config.d/00-hardening.conf" \
  "sudo sed -i 's/^AllowAgentForwarding yes/AllowAgentForwarding no/' /etc/ssh/sshd_config.d/00-hardening.conf" "AllowAgentForwarding must be no"
check "verify fails when the SSH user is in the docker group" boot_reset_caught \
  "sudo usermod -aG docker deploy" \
  "sudo gpasswd -d deploy docker" "is in the docker group"
restart_policy_caught() {
  "${ssh_vm[@]}" 'sudo tar -cf /tmp/empty-image.tar --files-from /dev/null && sudo docker import /tmp/empty-image.tar restart-test >/dev/null && sudo docker run -d --name restart-test --mount type=bind,src=/usr/bin/sleep,dst=/sleep,readonly --mount type=bind,src=/lib,dst=/lib,readonly --mount type=bind,src=/lib64,dst=/lib64,readonly restart-test /sleep 600' || return 1
  boot_reset_caught \
    'sudo docker update --restart=on-failure restart-test >/dev/null' \
    'sudo docker rm -f restart-test >/dev/null; sudo docker image rm restart-test >/dev/null; sudo rm /tmp/empty-image.tar' \
    'Containers that stay stopped after a Docker restart or reboot: /restart-test'
}
# on-failure, not no: only the unless-stopped/always allowlist rejects it.
check "verify names a running container whose restart policy is not unless-stopped or always" restart_policy_caught
# Comment-only sources test detection without adding another package repository to the VM.
docker_origin_caught() {
  local source origin
  for source in /etc/apt/sources.list.d/test-docker.list /etc/apt/sources.list.d/test-docker.sources; do
    "${ssh_vm[@]}" "echo '# download.docker.com' | sudo tee $source >/dev/null" || return 1
    cool; play harden.yml || return 1
    "${ssh_vm[@]}" "sudo test ! -e /etc/apt/apt.conf.d/52hardening-docker" || return 1
    cool; play harden.yml -e docker_auto_updates=true || return 1
    "${ssh_vm[@]}" "sudo test -f /etc/apt/apt.conf.d/52hardening-docker" || return 1
    boot_reset_caught \
      "sudo mv /etc/apt/apt.conf.d/52hardening-docker /tmp/test-docker-origin" \
      "sudo mv /tmp/test-docker-origin /etc/apt/apt.conf.d/52hardening-docker" \
      "Docker's apt repository is configured but its origin is not allowed" -e docker_auto_updates=true || return 1
    cool; play verify.yml -e docker_auto_updates=true || return 1
    boot_reset_caught \
      "echo 'Unattended-Upgrade::Origins-Pattern:: \"origin=Docker,label=Docker CE,component=nightly\";' | sudo tee /etc/apt/apt.conf.d/52hardening-docker >/dev/null" \
      "echo 'Unattended-Upgrade::Origins-Pattern:: \"c=stable,l=Docker CE,o=Docker\";' | sudo tee /etc/apt/apt.conf.d/52hardening-docker >/dev/null" \
      "Docker's apt repository is configured but its origin is not allowed" -e docker_auto_updates=true || return 1
    cool; play verify.yml -e docker_auto_updates=true || return 1
    for origin in \
      'Unattended-Upgrade::Allowed-Origins:: "Docker:${distro_codename}";' \
      'Unattended-Upgrade::Origins-Pattern:: "o=Docker,l=Docker CE,c=stable,n=${distro_codename}";'; do
      "${ssh_vm[@]}" "printf '%s\n' '$origin' | sudo tee /etc/apt/apt.conf.d/52hardening-docker >/dev/null" || return 1
      cool; play verify.yml -e docker_auto_updates=true || return 1
    done
    "${ssh_vm[@]}" "sudo rm $source" || return 1
  done
  cool; play harden.yml || return 1
  "${ssh_vm[@]}" "sudo test ! -e /etc/apt/apt.conf.d/52hardening-docker"
}
check "Docker origins require stable, accept codename variables for both forms, and are removed without a repository" docker_origin_caught
cool; check "verify passes again after each case is undone" play verify.yml

echo
echo "$passes PASSED, $fails FAILED, $skips SKIPPED ($((passes + fails)) checks run)"
echo "Log of the last step: $work/last.log"
[ "$keep" = "--keep" ] && echo "VM left running: ssh -o UserKnownHostsFile=$work/known_hosts -i $work/key -p $port deploy@127.0.0.1   (stop: kill $qemu_pid $http_pid)"
exit "$fails"
