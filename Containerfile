# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ghcr.io/projectbluefin/bluefin:stable

FROM ${BASE_IMAGE} AS qc71-builder

RUN <<'EOF' bash
set -euo pipefail

FEDORA="$(rpm -E %fedora)"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 config-manager addrepo \
    --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 install -y --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" \
    akmods \
    kmodtool

dnf5 install -y \
    --setopt=install_weak_deps=0 \
    --setopt=tsflags=noscripts \
    akmod-slimbook-qc71

install -d -m 1777 /tmp /var/tmp

runuser -u akmods -- akmodsbuild \
    --kernels "${KERNEL}" \
    --outputdir /tmp \
    /usr/src/akmods/slimbook-qc71-kmod-*.src.rpm

cp /tmp/kmod-slimbook-qc71-"${KERNEL}"-*.rpm /qc71.rpm
EOF

FROM ${BASE_IMAGE}

RUN --mount=type=bind,from=qc71-builder,source=/qc71.rpm,target=/run/qc71.rpm <<'EOF' bash
set -euo pipefail

FEDORA="$(rpm -E %fedora)"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 config-manager addrepo \
    --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 install -y --setopt=install_weak_deps=0 \
    /run/qc71.rpm \
    slimbook-meta-executive

depmod -a "${KERNEL}"
modinfo -k "${KERNEL}" qc71_laptop
systemctl enable slimbook-service.service

rm -f /etc/yum.repos.d/slimbook.repo
dnf5 clean all

rm -rf \
    /run/dnf \
    /var/cache/libdnf5 \
    /var/lib/dnf/repos
rm -f \
    /var/cache/ldconfig/aux-cache \
    /var/log/dnf5.log
EOF

RUN bootc container lint --fatal-warnings