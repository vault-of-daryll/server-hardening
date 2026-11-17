# Changelog

Versions follow [Semantic Versioning](https://semver.org/). Before 1.0.0, a minor version (0.x.0) may change what the kit does to a server; a patch version (0.x.y) only fixes bugs and docs. Each release is a `vX.Y.Z` tag on `main`.

## [Unreleased]

## [0.1.0]

First public release.

- `harden.yml`: key-only SSH through one drop-in file, ufw with SSH rate-limited, kernel settings, automatic security updates (Docker's stable channel is opt-in with `docker_auto_updates=true` when its repository is used) and Docker defaults, with a key-login check before and after and an automatic undo.
- `verify.yml`: proves every control on the server, including restart policies for running containers and docker-group membership for every allowed SSH user, and changes nothing.
- Kernel settings include `fs.protected_fifos=2`, `net.core.bpf_jit_harden=2` and `kernel.sysrq=0`.
- Tests: containers on Ubuntu 24.04, Ubuntu 26.04 and Debian 13, and a QEMU VM test for each.
- Leak guards: an allowlist `.gitignore` and pre-commit checks of staged blobs, paths and the allowlist, a commit-message private-pattern check, a pre-push check of every outgoing commit and tag (private patterns, binary files and gitleaks), a refusal of binary files such as screenshots, and hook regression tests with redacted diagnostics.
- Kernel settings live in `/etc/sysctl.d/99-zz-hardening.conf`, after every distribution file; a `90-hardening.conf` left by a pre-release copy is removed.
