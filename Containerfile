# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ghcr.io/projectbluefin/bluefin:stable

FROM ${BASE_IMAGE} AS packages

COPY <<'REPO' /inputs/build-inputs.repo
[build-inputs]
name=Build inputs
baseurl=file:///run/build-inputs/rpms
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch
       file:///run/build-inputs/slimbook.asc
REPO

RUN --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail

FEDORA="$(rpm -E %fedora)"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
SLIMBOOK_REPO="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}"

dnf5 config-manager addrepo \
    --from-repofile="${SLIMBOOK_REPO}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 --refresh download -y \
    --resolve \
    --arch=x86_64 \
    --arch=noarch \
    --destdir=/inputs/rpms \
    --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" \
    akmods \
    kmodtool \
    akmod-slimbook-qc71 \
    slimbook-meta-executive

curl -fsSL "${SLIMBOOK_REPO}/repodata/repomd.xml.key" \
    -o /inputs/slimbook.asc

dnf5 install -y --setopt=install_weak_deps=0 createrepo_c
createrepo_c /inputs/rpms

cd /inputs
sha256sum rpms/*.rpm slimbook.asc | LC_ALL=C sort > manifest.sha256
EOF

FROM scratch AS inputs
COPY --from=packages /inputs/ /

FROM ${BASE_IMAGE} AS qc71-builder

RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail

KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 --repo=build-inputs install -y --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" \
    akmods \
    kmodtool

dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 \
    --setopt=tsflags=noscripts \
    akmod-slimbook-qc71

chmod 1777 /tmp /var/tmp

runuser -u akmods -- akmodsbuild \
    --kernels "${KERNEL}" \
    --outputdir /tmp \
    /usr/src/akmods/slimbook-qc71-kmod-*.src.rpm

cp /tmp/kmod-slimbook-qc71-"${KERNEL}"-*.rpm /qc71.rpm
EOF

FROM ${BASE_IMAGE} AS final

RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=bind,from=qc71-builder,source=/qc71.rpm,target=/run/qc71.rpm \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=tmpfs,target=/var/cache \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=tmpfs,target=/var/lib/dnf <<'EOF' bash
set -euo pipefail

KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 \
    --exclude='akmod-*' \
    /run/qc71.rpm \
    slimbook-meta-executive

depmod -a "${KERNEL}"
modinfo -k "${KERNEL}" qc71_laptop
modinfo -k "${KERNEL}" dwmac-motorcomm
systemctl enable slimbook-service.service
EOF

RUN bootc container lint --fatal-warnings
