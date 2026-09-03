FROM ghcr.io/ublue-os/bluefin-dx:stable

RUN <<'EOF'
set -euo pipefail

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
LABEL org.opencontainers.image.description="Minimal Bluefin DX image for the Slimbook Executive"

RUN bootc container lint