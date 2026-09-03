ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin-dx:stable

FROM ${BASE_IMAGE} AS qc71-builder

RUN <<'EOF'
set -euo pipefail

kernel="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
fedora="$(rpm -E %fedora)"
arch="$(rpm -E '%{_arch}')"

dnf5 config-manager addrepo \
    --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${fedora}/home:Slimbook.repo"

dnf5 install -y \
    "kernel-devel-${kernel}" \
    akmods \
    kmodtool

dnf5 install -y \
    --setopt=tsflags=noscripts \
    akmod-slimbook-qc71

install -d /out
dnf5 download --destdir=/out slimbook-qc71-kmod-common

install -d -o akmods -g akmods /var/lib/akmods
chmod 1777 /tmp

srpm=(/usr/src/akmods/slimbook-qc71-kmod-*.src.rpm)

runuser -u akmods -- bash -c \
    'cd /var/lib/akmods && HOME=/var/lib/akmods akmodsbuild --target "$1" --kernels "$2" "$3"' \
    _ "${arch}" "${kernel}" "${srpm[0]}"

kmod_rpm=(/var/lib/akmods/kmod-slimbook-qc71-"${kernel}"-*.rpm)
install -m 0644 "${kmod_rpm[0]}" /out/
EOF


FROM ${BASE_IMAGE}

COPY --from=qc71-builder /out/ /tmp/qc71/

RUN <<'EOF'
set -euo pipefail

kernel="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 install -y \
    --setopt=install_weak_deps=False \
    /tmp/qc71/*.rpm

depmod -a "${kernel}"

test "$(modinfo -k "${kernel}" -F name qc71_laptop)" = "qc71_laptop"
test "$(modinfo -k "${kernel}" -F vermagic qc71_laptop | cut -d' ' -f1)" = "${kernel}"

rm -rf /tmp/qc71
dnf5 clean all

. /usr/lib/os-release
original_version="${VERSION}"

sed -i \
    -e 's/^NAME=.*/NAME="Bluefin DX Slimbook"/' \
    -e "s|^VERSION=.*|VERSION=\"${original_version} + Slimbook\"|" \
    -e "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Bluefin DX Slimbook (${original_version})\"|" \
    /usr/lib/os-release

ostree container commit
EOF

LABEL org.opencontainers.image.title="Bluefin DX Slimbook"
LABEL org.opencontainers.image.description="Bluefin DX image for the Slimbook Executive"

RUN bootc container lint