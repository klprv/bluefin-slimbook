# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin-dx:stable
ARG QC71_SIGN=true

# Resolve one package snapshot for both the check and the build.
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
ARCH="$(rpm -E '%{_arch}')"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')"
[[ -n "${KERNEL}" && "${KERNEL}" != *$'\n'* ]]
SLIMBOOK_REPO="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}"

mkdir -p /inputs/rpms
printf '%s\n' "${KERNEL}" > /inputs/kernel

dnf5 config-manager addrepo \
    --from-repofile="${SLIMBOOK_REPO}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 --refresh download --resolve \
    --arch="${ARCH}" --arch=noarch \
    --destdir=/inputs/rpms --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" akmods kmodtool \
    akmod-slimbook-qc71 slimbook-meta-executive

curl -fsSL "${SLIMBOOK_REPO}/repodata/repomd.xml.key" -o /inputs/slimbook.asc
dnf5 install -y --setopt=install_weak_deps=0 createrepo_c
createrepo_c /inputs/rpms

# Ignore generated repository timestamps; hash the actual inputs.
cd /inputs
sha256sum kernel build-inputs.repo slimbook.asc rpms/*.rpm \
    | LC_ALL=C sort -k2 > manifest.sha256
EOF

FROM scratch AS inputs
COPY --from=packages /inputs/ /

# Compile only QC71, for the kernel shipped inside the image.
FROM ${BASE_IMAGE} AS qc71-builder
ARG QC71_SIGN

RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail
KERNEL="$(cat /run/build-inputs/kernel)"
(cd /run/build-inputs && sha256sum --check --quiet manifest.sha256)

# Some Bluefin images register kernel-devel without shipping its files.
if rpm -q "kernel-devel-${KERNEL}" >/dev/null 2>&1 && \
   [[ ! -f "/usr/src/kernels/${KERNEL}/Makefile" ]]; then
    rpm -e --nodeps "kernel-devel-${KERNEL}"
fi

dnf5 --repo=build-inputs install -y --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" akmods kmodtool
test -f "/usr/src/kernels/${KERNEL}/Makefile"

# Do not let this source package build for the CI runner's kernel.
dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 --setopt=tsflags=noscripts \
    akmod-slimbook-qc71
EOF

RUN --network=none \
    --mount=type=secret,id=qc71_signing_key \
    --mount=type=secret,id=qc71_signing_cert \
    --mount=type=tmpfs,target=/etc/pki/akmods \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
ARCH="$(rpm -E '%{_arch}')"
[[ "${QC71_SIGN}" == true || "${QC71_SIGN}" == false ]]

# PRs compile unsigned; release builds must have the real matching key pair.
if [[ "${QC71_SIGN}" == true ]]; then
    openssl x509 -in /run/secrets/qc71_signing_cert -checkend 0 -noout
    openssl x509 -in /run/secrets/qc71_signing_cert -pubkey -noout > /tmp/cert.pub
    openssl pkey -in /run/secrets/qc71_signing_key -passin pass: -pubout > /tmp/key.pub
    cmp /tmp/cert.pub /tmp/key.pub

    install -d -m 0750 -o root -g akmods /etc/pki/akmods/{certs,private}
    openssl x509 -in /run/secrets/qc71_signing_cert -outform DER \
        -out /etc/pki/akmods/certs/public_key.der
    chmod 0644 /etc/pki/akmods/certs/public_key.der
    install -m 0640 -o root -g akmods /run/secrets/qc71_signing_key \
        /etc/pki/akmods/private/private_key.priv
fi

chmod 1777 /tmp /var/tmp
install -d -o akmods -g akmods /var/lib/akmods
shopt -s nullglob
SOURCES=(/usr/src/akmods/slimbook-qc71-kmod-*.src.rpm)
[[ ${#SOURCES[@]} -eq 1 ]]
runuser -u akmods -- env HOME=/var/lib/akmods \
    akmodsbuild --target "${ARCH}" --kernels "${KERNEL}" \
    --outputdir /tmp "${SOURCES[0]}"

RPMS=(/tmp/kmod-slimbook-qc71-"${KERNEL}"-*.rpm)
[[ ${#RPMS[@]} -eq 1 ]]
install -D -m 0644 "${RPMS[0]}" /out/qc71.rpm
if [[ "${QC71_SIGN}" == true ]]; then
    install -m 0644 /etc/pki/akmods/certs/public_key.der /out/qc71-signing.der
fi
EOF

# Fresh Bluefin DX plus Executive's runtime dependencies. No build tools copied.
FROM ${BASE_IMAGE} AS final
ARG QC71_SIGN

RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=bind,from=qc71-builder,source=/out,target=/run/qc71 \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=tmpfs,target=/var/cache \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=tmpfs,target=/var/lib/dnf <<'EOF' bash
set -euo pipefail
KERNEL="$(cat /run/build-inputs/kernel)"
(cd /run/build-inputs && sha256sum --check --quiet manifest.sha256)

# Check upstream RPM signatures; only the locally built RPM is exempt.
dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 --setopt=localpkg_gpgcheck=0 \
    --exclude='akmod-*' /run/qc71/qc71.rpm slimbook-meta-executive

depmod -a "${KERNEL}"
VERMAGIC="$(modinfo -k "${KERNEL}" -F vermagic qc71_laptop)"
[[ "${VERMAGIC%% *}" = "${KERNEL}" ]]
[[ "${QC71_SIGN}" == true || "${QC71_SIGN}" == false ]]
if [[ "${QC71_SIGN}" == false ]]; then
    echo 'PR validation: module compiled; release signature checks are not run.'
    exit 0
fi

# Verify the installed module's CMS signature, not just its signer label.
python3 - "$(modinfo -k "${KERNEL}" -n qc71_laptop)" <<'PY'
import gzip
import lzma
import pathlib
import struct
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if path.suffix == ".xz":
    data = lzma.decompress(data)
elif path.suffix == ".gz":
    data = gzip.decompress(data)
elif path.suffix == ".zst":
    data = subprocess.check_output(["zstd", "-dc", str(path)])
marker = b"~Module signature appended~\n"
if not data.endswith(marker) or len(data) < len(marker) + 12:
    sys.exit("QC71 has no module signature")
end = len(data) - len(marker) - 12
_, _, kind, signer_len, key_len, _, length = struct.unpack(
    ">BBBBB3sI", data[end:end + 12])
if kind != 2 or signer_len or key_len or not 0 < length < end:
    sys.exit("Unsupported QC71 signature trailer")
pathlib.Path("/tmp/qc71.unsigned").write_bytes(data[:end - length])
pathlib.Path("/tmp/qc71.p7s").write_bytes(data[end - length:end])
PY
openssl x509 -inform DER -in /run/qc71/qc71-signing.der -out /tmp/qc71.crt
openssl cms -verify -binary -inform DER -in /tmp/qc71.p7s \
    -content /tmp/qc71.unsigned -nointern -certfile /tmp/qc71.crt \
    -noverify -out /dev/null
EOF

RUN bootc container lint --fatal-warnings
