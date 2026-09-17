ARG BASE_IMAGE=ghcr.io/projectbluefin/bluefin:stable


FROM ${BASE_IMAGE} AS qc71-builder

RUN <<'EOF'
set -euo pipefail

FEDORA="$(rpm -E %fedora)"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
ARCH="$(rpm -E '%{_arch}')"

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

install -d -o akmods -g akmods /var/lib/akmods

SRPM="$(find /usr/src/akmods \
    -maxdepth 1 \
    -name 'slimbook-qc71-kmod-*.src.rpm' \
    -print -quit)"

test -n "${SRPM}"

su -s /bin/bash akmods -c \
    "cd /var/lib/akmods && \
     HOME=/var/lib/akmods \
     akmodsbuild \
        --target ${ARCH} \
        --kernels ${KERNEL} \
        ${SRPM}"

cp /var/lib/akmods/kmod-slimbook-qc71-${KERNEL}-*.rpm /qc71.rpm
EOF


FROM ${BASE_IMAGE}

COPY --from=qc71-builder /qc71.rpm /tmp/qc71.rpm

RUN <<'EOF'
set -euo pipefail

FEDORA="$(rpm -E %fedora)"

dnf5 config-manager addrepo \
    --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 install -y --setopt=install_weak_deps=0 \
    /tmp/qc71.rpm \
    slimbook-meta-executive

systemctl enable slimbook-service.service

rm -f \
    /tmp/qc71.rpm \
    /etc/yum.repos.d/slimbook.repo

dnf5 clean all

bootc container lint --fatal-warnings
EOF