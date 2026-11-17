# Server hardening kit

This kit locks down a fresh Ubuntu or Debian VPS: key-only SSH, a firewall that denies incoming traffic, automatic security updates, safer kernel settings and safer Docker defaults. It is two Ansible playbooks. `harden.yml` makes the changes and `verify.yml` proves each one on the server without changing anything.

It started from [dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening) (commit `06228ad`, 2026-10-11, Apache-2.0). Most of that collection was left out, and the parts that were kept were brought up to date. [What changed from upstream](#what-changed-from-upstream) lists each difference and why.

## What you need

- Ansible on your own machine, not on the server. The controller needs Python 3.13 or newer because ansible-core 2.22 requires it. Debian 13 and Ubuntu 26.04 work as they are. Stock Ubuntu 24.04 has Python 3.12, so install 3.13 first (for example with `uv python install 3.13` or from the deadsnakes PPA) and build the environment with it. Your machine can run Linux or macOS; on Windows, use WSL. Get the kit with `git clone https://github.com/vault-of-daryll/server-hardening.git`, then, inside its folder, install the pinned versions in a virtual environment (`.venv` is ignored by Git):

  ```bash
  python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-controller.txt && ansible-galaxy collection install -r requirements.yml
  ```

- A server running Ubuntu 24.04, Ubuntu 26.04 or Debian 13. The kit refuses any other system, since these are the ones the tests cover.
- A non-root user on the server with your SSH public key in `~/.ssh/authorized_keys` and passwordless `sudo`. The kit turns off root login, so it refuses to run as root, and only this user may log in over SSH afterwards (see `ssh_allow_users` in `inventory.example.ini`). If the VPS gave you only root, create the user while logged in as root:

  ```bash
  adduser deploy
  install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
  install -m 600 -o deploy -g deploy /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
  echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy && chmod 440 /etc/sudoers.d/deploy && visudo -c
  ```

  Then check it from your own machine. This must print `ok` without asking for any password:

  ```bash
  ssh deploy@203.0.113.10 'sudo -n true && echo ok'
  ```

- A way in that doesn't use SSH. Your VPS provider's web console (some providers call it VNC) logs in with a password. Give your login user a password with `sudo passwd deploy` and store it safely, then log in on the console once before you start, so you know it works. The kit turns password login off for SSH only, so the console keeps working with that password. If SSH ever breaks, the console is the only way back in.

## Use it

1. Copy `inventory.example.ini` to `inventory.ini` and put your server on the host line: `vps1 ansible_host=203.0.113.10 ansible_user=deploy ansible_port=22`. Set `ansible_port` to the port SSH listens on now; the kit keeps that port. Ansible uses the keys in your `ssh-agent` and `~/.ssh`, as `ssh` does; to use one key file only, add `ansible_ssh_private_key_file=~/.ssh/id_ed25519` to the same line. Settings that apply to every server go under `[servers:vars]`. Git ignores `inventory.ini`.
2. Set `open_ports` for anything besides SSH that must be reachable, such as `[80, 443]`. `ufw` allows these ports, and a container serving one of them may publish it on every address (`"443:443"`); every other container port must be bound to `127.0.0.1` (see [Docker and the firewall](#docker-and-the-firewall)). Leave it empty for a host reached only through a Cloudflare Tunnel.
3. Do a dry run. It reports what would change. The only thing it changes is installing `python3-apt` if it is missing, because Ansible needs it to read the package list:

   ```bash
   ansible-playbook -i inventory.ini harden.yml --check --diff
   ```

4. Keep an SSH session to the server open in another terminal, then apply:

   ```bash
   ansible-playbook -i inventory.ini harden.yml
   ```

5. Prove it:

   ```bash
   ansible-playbook -i inventory.ini verify.yml
   ```

   On the first run, you may see one of two expected failures. Verify stops at the first failed assertion, so it shows only one at a time: Docker must be restarted once to load its new defaults (see [Docker and the firewall](#docker-and-the-firewall)), and a reboot is pending when updates replaced the kernel or core libraries. With the console open, run `sudo reboot`, which restarts Docker too (check your containers' restart policy first, as that section says), wait a minute, and run `verify.yml` again. Close your spare SSH session only after a new SSH login works and `verify.yml` passes.

## How it keeps you from being locked out

The first thing `harden.yml` does is open a new SSH connection from your machine, with Ansible's key (`ansible_ssh_private_key_file`) and your `ansible_ssh_common_args`. That connection may log in with a key only, never a password. It never reuses an already open connection (SSH multiplexing through a `ControlPath` socket), so the test can't pass on a session that logged in before the change. Over that connection it runs `sudo -n true`. If that fails, the play stops before it changes anything. A missing key, a wrong user, `sudo` that asks for a password or a changed host key all stop it here, while password login still works.

It also stops early when `sshd` does not listen on the port in your inventory, when `sshd_config` does not read the `sshd_config.d` folder, or when `ufw` is off but already holds `deny` or `reject` rules, which could block SSH the moment it is turned on.

The firewall's SSH port is opened before the firewall is turned on. Right after `ufw` is on, the kit opens another new key-only connection. If that fails and this run turned `ufw` on, it turns `ufw` off again and stops, so a firewall rule can't shut you out either. A firewall that was already on stays on, since the kit only adds rules to it.

The new SSH settings then go in as one step that undoes itself if any part fails:

1. Write the drop-in file `/etc/ssh/sshd_config.d/00-hardening.conf`, which `sshd -t` (a syntax check) must accept. A drop-in is a small file that `sshd_config` reads in addition to its own settings, so package updates never touch it.
2. Ask `sshd -T` (the settings `sshd` will actually use) for the settings that will apply to you and to root on this exact connection (your address, the server's address and port), and require key-only login with no root login. This catches a main `sshd_config` that turns passwords on before it reads the drop-in. It runs on every real run, so a later change that overrides the drop-in also stops the play, with nothing changed. The drop-in sets `UseDNS no`, so `Match Host` rules see the same address the check uses.
3. Reload `sshd` rather than restart it, so your open session survives.
4. Open a new key-only connection again and run `sudo -n true`.

If any of these fails, the kit puts the previous drop-in back, or removes the new one, reloads `sshd` and stops. Your open session is the last resort if even that goes wrong.

## SSH only through a tunnel

By default the firewall leaves the SSH port open, with key-only login and rate limiting. A server already reached through a Cloudflare Tunnel can close it completely, so nothing on the internet can even try to log in:

1. Set up SSH through the tunnel first, as described in Cloudflare's guide for [SSH with cloudflared](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/). Check that `ssh -o ProxyCommand='cloudflared access ssh --hostname ssh.example.com' deploy@ssh.example.com` works.
2. In `inventory.ini`, set `ansible_ssh_common_args` to that `ProxyCommand` and add `ssh_public=false`.
3. Run the kit as usual. It refuses `ssh_public=false` unless the run comes through a `ProxyCommand` or `ProxyJump` (not `none`) and `sshd` sees it arrive on the server's loopback address, which is where a `cloudflared` on the server connects. A jump host, or a `cloudflared` container that reaches the host over a Docker network, arrives from another address and would be blocked by the firewall, so the kit stops before closing anything. If the new login after the firewall change still fails, the kit turns `ufw` off again when this run was the one that turned it on.

Keep tokens out of `ProxyCommand` anyway. The kit hides the command line of its own logins, but Ansible's connection errors and `-vvv` output can still print it, and a `--service-token-secret` there would land in your terminal or CI log. `cloudflared` reads service tokens from the `TUNNEL_SERVICE_TOKEN_ID` and `TUNNEL_SERVICE_TOKEN_SECRET` environment variables instead.

If a firewall rule for the SSH port already exists, the kit leaves it, and `verify.yml` fails until you delete it. Find it with `sudo ufw status numbered`, delete it by its number with `sudo ufw delete <number>`, and then, before you close your session, check that a new login through the tunnel still works.

## What `verify.yml` checks

| Control | How it is proved |
|---|---|
| SSH is key-only | `sshd -T` for your user and for root, on your connection, shows `passwordauthentication no`, `kbdinteractiveauthentication no`, `authenticationmethods publickey` and `pubkeyauthentication yes` |
| No root login | the same `sshd -T` output shows `permitrootlogin no` |
| Only your account | the `allowusers` entries in `sshd -T` are exactly your user, or exactly `ssh_allow_users` when you set it; an extra name or `*` from another file fails |
| No X11 or agent forwarding | the same `sshd -T` output shows `x11forwarding no` and `allowagentforwarding no` |
| No Docker group privilege | `id -nG` shows every user in `ssh_allow_users` (default: `ansible_user`) is not in the `docker` group, which gives root without a password; use `sudo docker` instead |
| No weak SSH crypto | no CBC, SHA-1 or MD5 in the effective ciphers, MACs or key exchange |
| Password login really fails | a login from your machine that offers only a password gets `Permission denied (publickey).`, meaning the server offers nothing but keys |
| Kernel settings | every setting from `templates/90-hardening.sysctl.j2`, installed as `/etc/sysctl.d/99-zz-hardening.conf`, has its value, including `fs.protected_fifos=2`, `net.core.bpf_jit_harden=2` and `kernel.sysrq=0`, and nothing will reset one at the next boot: `IPT_SYSCTL=` is empty in `/etc/default/ufw`, and `apport`, where installed, is set to `enabled=0`, disabled and stopped |
| No pending reboot | `/var/run/reboot-required` does not exist, so the patched kernel and libraries are the ones running |
| Firewall | `ufw` is active, denies incoming, covers IPv6 and allows nothing but SSH (unless `ssh_public=false`) and `open_ports` |
| Automatic updates | the `unattended-upgrades` package is installed, unattended upgrades are on, the merged apt configuration allows the security archive and Docker's stable origin when `docker_auto_updates=true` and `download.docker.com` is configured, both apt timers are enabled and running, and the last upgrade run did not fail |
| Docker ports | no running container publishes a port on any address other than loopback unless it is in `open_ports`; the check fails if Docker can't be asked, or if `/var/run/docker.sock` exists with no `docker` client on `PATH` (Docker from apt or a static install; snap Docker keeps its config elsewhere, so it fails verify and isn't supported) |
| Docker restart policies | every running container has the restart policy `unless-stopped` or `always`; failures name the containers |
| Docker defaults | `daemon.json` sets `no-new-privileges` and log rotation, and Docker has been restarted since the file changed |

## Docker and the firewall

Docker publishes container ports through its own firewall rules, and those rules run before `ufw` sees the traffic ([Docker docs](https://docs.docker.com/engine/network/packet-filtering-firewalls/)). A `ports: "8000:8000"` line in a Compose file is therefore open to the internet even when `ufw` says it is denied. Bind such ports to `127.0.0.1`, as in `"127.0.0.1:8000:8000"`. The verify play fails when it finds a public port you did not list.

Docker Engine auto-updates are opt-in (`docker_auto_updates=false` by default): an engine upgrade restarts dockerd and can stop containers, and the kit never restarts Docker on its own. When you set `docker_auto_updates=true` and an apt source mentions `download.docker.com`, the kit adds Docker's stable channel (`origin=Docker,label=Docker CE,component=stable`) to unattended upgrades in `/etc/apt/apt.conf.d/52hardening-docker`. Docker publishes no separate security archive, so this allows every stable update, but never its test or nightly builds. The kit removes this file when the option is off or the repository is absent. Ubuntu's own `docker.io` package is already covered by its security origin.

Every user allowed over SSH must not belong to the `docker` group: it gives root without a password. `verify.yml` reports membership and tells you to run `sudo gpasswd -d <user> docker` and use `sudo docker`. The kit does not change group membership.

Docker from snap is not supported. The kit detects it from `/snap/docker`, even when `dockerd` has no alias on `PATH`, prints a message and skips all Docker tasks. `verify.yml` refuses snap Docker before checking `/etc/docker/daemon.json`, even if an old copy exists. Use Docker's apt packages or a static install.

The kit creates `/etc/docker` when it is missing and leaves an existing directory's permissions alone. It writes `/etc/docker/daemon.json` only when the file does not exist yet, so it never overwrites settings you made yourself, and Docker must accept the file before it is written. If you already have one, `verify.yml` needs `"no-new-privileges": true` and a `"log-opts"` entry with `"max-size"` in it; `templates/daemon.json.j2` shows the kit's full set. Check your edited file with `sudo dockerd --validate --config-file /etc/docker/daemon.json` before the restart. The kit never restarts Docker. Restart it yourself at a quiet moment with `sudo systemctl restart docker`. `verify.yml` names and rejects every running container whose restart policy is not `unless-stopped` or `always` (`on-failure` doesn't bring a container back after a reboot); give it `restart: unless-stopped` (or `always`) in its Compose service, or run `sudo docker update --restart unless-stopped <name>`, so it comes back after a Docker restart or reboot. That first restart stops every container, and containers without a restart policy stay stopped, so check that your Cloudflare Tunnel container has `restart: unless-stopped`. After that, `live-restore` keeps containers running across daemon restarts, as long as `daemon.json` sets `"live-restore": true`; the kit's file does, so add it when you merge the defaults into a file of your own. `verify.yml` fails until the restart is done.

## Test it locally

`tests/container-test.sh` runs the kit against a throwaway container with `podman`, with SSH on port 2222, and deletes the container afterwards. It touches no real server and leaves your `~/.ssh/known_hosts` alone. It checks that:

- `verify.yml` fails before hardening
- the dry run leaves SSH unchanged
- a real run hardens the server, a second dry run reports no changes, and `verify.yml` then passes
- an untrusted key stops the run before anything changes
- the undo step removes a new drop-in when the main config overrides it, and keeps one that existed before
- a rerun stops when something later overrides the drop-in
- an inactive `ufw` holding a `deny` rule for the SSH port stops the run
- your SSH options naming a live connection socket, with `-o ControlPath` or `-S`, can't fool the guard
- `ssh_public=false` is refused with no tunnel, with `ProxyCommand=none`, or with a tunnel that reaches `sshd` from a non-loopback address, and works through a tunnel that ends on the server's loopback
- If the login after a firewall change fails, the run stops. It turns `ufw` off if the run enabled it, and leaves `ufw` active if it was already on.
- `AllowUsers` must match exactly: an extra account or a wildcard in another file fails, and a list you set on purpose passes
- `verify.yml` fails when a later apt file removes the security origins, or when Docker can't be asked
- A static `dockerd` with no `/etc/docker` gets a `daemon.json`. An existing `/etc/docker` keeps its `0700` permissions.
- `verify.yml` fails when Docker has no recorded start time, even if `daemon.json` is old.
- Snap Docker without a `dockerd` alias is left alone with a message. `verify.yml` refuses it with or without an old, valid `/etc/docker/daemon.json`.

The containers keep each system's own SSH setup, including socket activation on Ubuntu. Run it from the kit folder. `TEST_IMAGE` picks the base image; it defaults to Ubuntu 24.04, pinned by digest:

```bash
bash tests/container-test.sh
```

A container shares your machine's kernel, so the test never applies or checks kernel settings (`--skip-tags kernel`). It does not run a real Docker daemon either.

`tests/vm-test.sh` covers what a container can't. It starts a throwaway Ubuntu 26.04 VM by default; `VM_IMAGE` also accepts `ubuntu-24.04` and `debian-13`. It uses QEMU and KVM, with SSH only on `127.0.0.1:2230`, and installs the distribution's `docker.io`. It needs `qemu-system-x86_64`, `qemu-img` and write access to `/dev/kvm`; on Fedora, `sudo dnf install qemu-kvm-core qemu-img`. The first run downloads the selected cloud image and checks Ubuntu images against `SHA256SUMS` or Debian's genericcloud image against `SHA512SUMS`, fetched over HTTPS from the image's directory. Each image keeps its own cached base and VM disk. Debian skips the two apport regression cases and prints them as skips, separate from passes. It checks that:

- the dry run, the real run and a second dry run with no changes all succeed
- `verify.yml` passes with the kernel settings included, but only after Docker has been restarted
- Docker runs with `no-new-privileges`, and the key login still works
- the VM really rebooted (its boot ID changed), and `verify.yml` still passes afterwards, so nothing puts a kernel setting back
- an older kit's `/etc/sysctl.d/90-hardening.conf` is removed, `/etc/sysctl.d/99-zz-hardening.conf` is installed, and `sysctl --system` keeps `fs.protected_fifos=2` after the distribution's `99-protect-links.conf`
- `verify.yml` rejects agent forwarding and membership in the `docker` group
- `verify.yml` names and rejects a running container whose restart policy is not `unless-stopped` or `always`
- Docker's update origin is required for `.list` and `.sources` entries and removed when the repository is absent; `verify.yml` rejects the nightly channel, accepts the stable channel with abbreviated fields, and expands `${distro_codename}` in both `Allowed-Origins` and `Origins-Pattern`

```bash
bash tests/vm-test.sh          # deletes the VM at the end
bash tests/vm-test.sh --keep   # leaves it running and prints the ssh command
VM_IMAGE=ubuntu-24.04 bash tests/vm-test.sh
VM_IMAGE=debian-13 bash tests/vm-test.sh
```

`tests/vm-lab.sh` uses the same `VM_IMAGE` selection and Netplan configuration on all three cloud images. Use the same `VM_IMAGE` when running `tests/vm-lab.sh --stop`.

The reboot check found two services that undo kernel settings after boot. `ufw` applies its own `/etc/ufw/sysctl.conf` each time it starts, which turns `log_martians` off, so the kit sets `IPT_SYSCTL=` in `/etc/default/ufw`. Ubuntu's crash reporter, `apport`, sets `fs.suid_dumpable` to 2 each time it starts, so the kit turns `apport` off where it is installed.

## Tested from the network

On 2026-11-17 a hardened Ubuntu 26.04 VM (`tests/vm-lab.sh`) was attacked from a second machine on the same network, with nmap and ssh-audit. SSH listened on port 2230 and no port was listed in `open_ports`. The addresses below are placeholders.

| Attack | Command | Result |
|---|---|---|
| Every TCP port, over IPv4 and over the public and link-local IPv6 addresses | `nmap -Pn -sS -p- 203.0.113.10` | Only 2230 open; the other 65,534 ports gave no reply |
| The 200 most common UDP ports | `nmap -Pn -sU --top-ports 200 203.0.113.10` | Nothing answered |
| Many connections in a row | the full TCP scan, then a new SSH login | SSH refused new connections for about two minutes (`ufw limit` and `PerSourcePenalties`) |
| Getting around the firewall | `nmap -f`, `nmap -g 53` and `nmap -sA` | Nothing new opened; unsolicited ACK packets were dropped on every closed port |
| Guessing passwords | `nmap --script ssh-brute`, then `ssh -o PubkeyAuthentication=no -p 2230 root@203.0.113.10` | `Permission denied (publickey).` The server never asks for a password, and the rate limit cut the guessing off |
| SSH algorithms | `ssh-audit -p 2230 203.0.113.10` | No failures or warnings; post-quantum key exchange first |
| A container port published on all addresses | `docker run -p 8080:80 …` | Reachable over IPv4 despite ufw, as described in [Docker and the firewall](#docker-and-the-firewall), and `verify.yml` fails on it. Bound to `127.0.0.1`, the port was unreachable |

## Publishing and contributing

Enable the hook before your first commit. It needs [gitleaks](https://github.com/gitleaks/gitleaks) and refuses the commit without it:

```bash
git config core.hooksPath .githooks
```

Put your own server addresses, home network addresses, usernames and server names in `.git/info/private-patterns`, one extended regular expression per line. This file stays inside `.git` and is never committed. For example, using documentation addresses and placeholder names:

```text
# Replace these examples with your own values; escape dots in addresses.
203\.0\.113\.10
198\.51\.100\.[0-9]+
example-admin
example-server
```

The pre-commit hook checks every staged added, modified, copied or renamed path against all patterns before checking file contents, without regard to case, and rejects paths outside the allowlist. Deleting a file is allowed; when its name matches a pattern, commit with `-m`, since the editor template lists the deleted path and the commit-msg hook checks it. Stage or discard any `.gitignore` edit before committing so the allowlist matches the index; only the root `.gitignore` is allowed, since a nested one could re-include an excluded file. The pre-merge-commit hook runs the same checks before an automatic merge commit. The pre-push hook is the last check before anything leaves your machine: it scans every outgoing branch or tag name and every outgoing commit's message, author, paths and changes, and any annotated tag message (even when the tag points at a commit pushed before), including changes made inside a merge, against the patterns, refuses binary files, and runs gitleaks on the outgoing range, so commits made where the other hooks never ran are still caught. The commit-msg hook checks the whole commit message file, comment lines included, because `-m`, `-F` and some cleanup modes keep lines starting with `#`. The pre-commit hook also refuses binary files such as screenshots, since nothing can check them for private data: document with text, and replace real values with placeholders. Both report the pattern line number without printing the pattern or matched text; a matching path is redacted. Blank lines and lines starting with `#` are skipped. Without this file, pre-commit still enforces the allowlist and runs gitleaks.

`--no-verify`, cherry-pick, rebase and `git am` skip the commit-time hooks, and the pre-push hook catches what they let through; `git push --no-verify` skips it too, so never use it here. Clones without `core.hooksPath` do not run them, and clones without `.git/info/private-patterns` skip the private-pattern checks. CI's gitleaks scan remains the server-side net for secrets; it does not check your private address and name patterns.

Keep inventories, scan output and logs outside the repository. `.gitignore` allows only the kit's named files; add a new file there on purpose before contributing it. Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Working on the kit

- Every push runs `.github/workflows/ci.yml`: `ansible-lint`, shell and hook syntax checks, the hook regression test, a gitleaks scan of the whole history, and the container test on Ubuntu 24.04, Ubuntu 26.04 and Debian 13. The `ci-ok` job requires all of those jobs to succeed and gives branch protection one stable check name. Actions and images are pinned by SHA or digest, and gitleaks by checksum. `ansible-core`, `ansible-lint` and the collection are pinned to exact versions; their own dependencies are not locked.
- Releases are `vX.Y.Z` tags on `main`, following Semantic Versioning; CHANGELOG.md lists what each one changes on a server. Dependabot keeps the pinned Actions and Python tools current.

## What changed from upstream

| Upstream | This kit | Why |
|---|---|---|
| Six roles, including Apache, MySQL, nginx and Windows | OS, SSH, firewall, updates and Docker only | A VPS for these projects runs none of the others |
| Supports many systems, including Fedora, RHEL and the BSDs | Ubuntu and Debian only | These are the systems the servers run, and every supported system needs its own tested firewall and update setup |
| Key exchange tops out at `sntrup761x25519-sha512` | `mlkem768x25519-sha256` first, filtered to what the server's `sshd` supports | ML-KEM has been the OpenSSH default since 10.0 (April 2025), and OpenSSH 10.5 can warn on non-post-quantum key exchange ([release notes](https://www.openssh.org/releasenotes.html)) |
| MACs include non-ETM `hmac-sha2-*`; older lists keep `hmac-sha1` and CTR ciphers | ETM MACs and AEAD ciphers only | Every supported OpenSSH has had them for years |
| `MaxAuthTries 2` | OpenSSH's default of 6 | With several keys in your agent, a low limit can reject the right key after the change; key-only login already stops guessing |
| Rewrites the whole `sshd_config` | One drop-in, `sshd_config.d/00-hardening.conf`, proved effective with `sshd -T` | Package updates keep their own file. The `00-` name wins over cloud-init's `50-cloud-init.conf`, which often turns password login back on, because `sshd` uses the first value it reads |
| No check that a key login works | A key-only login and `sudo` check before and after, with automatic undo | The kit's first rule is not to lock you out |
| `net.ipv4.ip_forward = 0` | Left alone | Docker needs forwarding, and turning it off breaks container networking |
| `tcp_timestamps = 0` and other legacy network settings | Dropped | Modern kernels randomise timestamp offsets, and turning timestamps off hurts TCP performance |
| `ptrace_scope = 2` | `1` | `2` lets only root attach to a process, which breaks ordinary debugging; `1` still stops one process attaching to another it did not start |
| Password ageing every 60 days and password-quality rules | Dropped | NIST SP 800-63B advises against forced rotation, and with key-only SSH no one logs in with a password |
| SUID removal, PAM, login.defs, core-dump limits and other OS tasks | Dropped, apart from `fs.suid_dumpable = 0` | They add risk to a fresh cloud image and protect little on a single-owner host |
| No firewall | `ufw` with IPv6, SSH rate-limited or closed behind a tunnel, and a check that nothing else is open | A fresh VPS often has none |
| No limit on who can log in | `AllowUsers` set to the account that runs the kit | A second account with a weak key can't be used to get in |
| No automatic updates | `unattended-upgrades` with its timers checked | Unpatched packages are the most common way in |
| No Docker hardening | Safer `daemon.json` defaults and a check for public ports | Docker skips the host firewall, as described above |

## What it does not do

- **It does not install fail2ban.** Once passwords are off, guessing them achieves nothing. `ufw limit` slows repeated SSH connections, and OpenSSH 9.8 and later penalise sources that fail repeatedly (`PerSourcePenalties`). Add fail2ban yourself if you want bans to show in a log.
- **It does not reboot.** Kernel updates wait until you reboot the server, and `verify.yml` fails while a reboot is pending. Run `verify.yml` now and then, or check for `/var/run/reboot-required`, and reboot at a quiet moment.
- **It does not change the SSH port.** It keeps the port in `ansible_port`. To move SSH, change it by hand, open the new port in `ufw` first, then update the inventory.
- **It does not remove firewall rules you added.** `verify.yml` fails on any rule beyond SSH and `open_ports`, and you decide whether to delete it.
- **It does not restart Docker.** See [Docker and the firewall](#docker-and-the-firewall).
