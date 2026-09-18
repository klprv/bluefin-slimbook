# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin-dx:stable


# -----------------------------------------------------------------------------
# Build inputs
# -----------------------------------------------------------------------------

FROM ${BASE_IMAGE} AS packages

COPY <<'REPO' /inputs/build-inputs.repo
[build-inputs]
name=Build inputs
baseurl=file:///run/build-inputs/rpms
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch
       file:///run/build-inputs/slimbook.asc
REPO

RUN --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail

FEDORA="$(rpm -E %fedora)"
ARCH="$(rpm -E '%{_arch}')"
KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
SLIMBOOK_REPO="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA}"

mkdir -p /inputs/rpms

dnf5 config-manager addrepo \
    --from-repofile="${SLIMBOOK_REPO}/home:Slimbook.repo" \
    --save-filename=slimbook

dnf5 --refresh download \
    --resolve \
    --arch="${ARCH}" \
    --arch=noarch \
    --destdir=/inputs/rpms \
    --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" \
    akmods \
    kmodtool \
    openssl \
    akmod-slimbook-qc71 \
    slimbook-meta-executive

curl --fail --silent --show-error --location \
    "${SLIMBOOK_REPO}/repodata/repomd.xml.key" \
    --output /inputs/slimbook.asc

dnf5 install -y --setopt=install_weak_deps=0 createrepo_c
createrepo_c /inputs/rpms

cd /inputs
sha256sum rpms/*.rpm slimbook.asc | LC_ALL=C sort > manifest.sha256
EOF

FROM scratch AS inputs
COPY --from=packages /inputs/ /


# -----------------------------------------------------------------------------
# Build and sign the QC71 module for the exact Bluefin kernel
# -----------------------------------------------------------------------------

FROM ${BASE_IMAGE} AS qc71-builder

RUN --network=none \
    --mount=type=secret,id=qc71_signing_key,required=true,mode=0400 \
    --mount=type=secret,id=qc71_signing_cert,required=true,mode=0400 \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp <<'EOF' bash
set -euo pipefail

KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
ARCH="$(rpm -E '%{_arch}')"

# Bluefin can carry a kernel-devel RPM database entry without the real headers.
rpm -e --nodeps "kernel-devel-${KERNEL}" 2>/dev/null || true

dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 \
    "kernel-devel-${KERNEL}" \
    akmods \
    kmodtool \
    openssl

test -d "/usr/src/kernels/${KERNEL}"

# Install only the QC71 akmod source. Scriptlets are intentionally skipped:
# the module is built explicitly for the immutable image kernel below.
dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 \
    --setopt=tsflags=noscripts \
    akmod-slimbook-qc71

# Validate that the certificate and private key belong to the same key pair.
CERT_PUB="$(
    openssl x509 -in /run/secrets/qc71_signing_cert -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum | cut -d ' ' -f 1
)"
KEY_PUB="$(
    openssl pkey -in /run/secrets/qc71_signing_key -pubout -outform DER |
    sha256sum | cut -d ' ' -f 1
)"
test "${CERT_PUB}" = "${KEY_PUB}"

install -d -m 0750 -o root -g akmods \
    /etc/pki/akmods/certs \
    /etc/pki/akmods/private

openssl x509 \
    -in /run/secrets/qc71_signing_cert \
    -outform DER \
    -out /etc/pki/akmods/certs/public_key.der

install -m 0640 -o root -g akmods \
    /run/secrets/qc71_signing_key \
    /etc/pki/akmods/private/private_key.priv

chown root:akmods /etc/pki/akmods/certs/public_key.der
chmod 0640 /etc/pki/akmods/certs/public_key.der

chmod 1777 /tmp /var/tmp
install -d -m 0755 -o akmods -g akmods /var/lib/akmods

runuser -u akmods -- \
    env HOME=/var/lib/akmods \
    akmodsbuild \
        --target "${ARCH}" \
        --kernels "${KERNEL}" \
        --outputdir /tmp \
        /usr/src/akmods/slimbook-qc71-kmod-*.src.rpm

QC71_RPM="$(
    find /tmp -maxdepth 1 -type f \
        -name "kmod-slimbook-qc71-${KERNEL}-*.rpm" \
        -print -quit
)"
test -n "${QC71_RPM}"

dnf5 install -y "${QC71_RPM}"

SIGNER="$(modinfo -k "${KERNEL}" -F signer qc71_laptop)"
test -n "${SIGNER}"

cp "${QC71_RPM}" /qc71.rpm
cp /etc/pki/akmods/certs/public_key.der /qc71-signing.der

# Never leave the private signing key in a committed build layer.
rm -f /etc/pki/akmods/private/private_key.priv
EOF


# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------

FROM ${BASE_IMAGE} AS final

RUN --network=none \
    --mount=type=bind,from=inputs,source=/,target=/run/build-inputs \
    --mount=type=bind,from=inputs,source=/build-inputs.repo,target=/etc/yum.repos.d/build-inputs.repo \
    --mount=type=bind,from=qc71-builder,source=/qc71.rpm,target=/run/qc71.rpm \
    --mount=type=bind,from=qc71-builder,source=/qc71-signing.der,target=/run/qc71-signing.der \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=tmpfs,target=/var/cache \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=tmpfs,target=/var/lib/dnf <<'EOF' bash
set -euo pipefail

KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"

# The only Slimbook package requested explicitly in the final image.
# slimbook-meta-executive pulls the model-specific userspace dependencies.
# The akmod source package is excluded because QC71 is already prebuilt above.
dnf5 --repo=build-inputs install -y \
    --setopt=install_weak_deps=0 \
    --exclude='akmod-*' \
    /run/qc71.rpm \
    slimbook-meta-executive

install -D -m 0644 \
    /run/qc71-signing.der \
    /usr/share/bluefin-slimbook/qc71-signing.der

depmod -a "${KERNEL}"

rpm -q slimbook-meta-executive >/dev/null
modinfo -k "${KERNEL}" qc71_laptop >/dev/null
test -n "$(modinfo -k "${KERNEL}" -F signer qc71_laptop)"

systemctl enable slimbook-service.service
EOF

RUN bootc container lint --fatal-warnings
