# Bluefin DX for Slimbook Executive

Minimal custom [Bluefin DX](https://projectbluefin.io/) image for a Slimbook Executive.

The final image explicitly installs only:

- `slimbook-meta-executive`

The package manager resolves the model-specific Slimbook userspace dependencies. The QC71 kernel module is built ahead of time for the exact Bluefin kernel and signed for Secure Boot.

## Image

```text
ghcr.io/klprv/bluefin-slimbook:stable
```

Base image:

```text
ghcr.io/ublue-os/bluefin-dx:stable
```

The workflow rebuilds when the Bluefin base image, Slimbook packages, build definition, or QC71 signing certificate changes.

## Signing keys

Three GitHub Actions secrets are required for publishing from `main`.

### QC71 module signing

Generate a dedicated, unencrypted key pair locally:

```bash
mkdir -m 700 qc71-keys

openssl req \
  -new \
  -x509 \
  -newkey rsa:3072 \
  -nodes \
  -sha256 \
  -days 3650 \
  -subj "/CN=Killian Provin Bluefin QC71/" \
  -keyout qc71-keys/qc71-signing.key \
  -out qc71-keys/qc71-signing.crt

openssl x509 \
  -in qc71-keys/qc71-signing.crt \
  -outform DER \
  -out qc71-keys/qc71-signing.der

chmod 600 qc71-keys/qc71-signing.key
```

Add these repository secrets:

- `QC71_SIGNING_KEY`: contents of `qc71-keys/qc71-signing.key`
- `QC71_SIGNING_CERT`: contents of `qc71-keys/qc71-signing.crt`

The private key is mounted into the build as a BuildKit secret and is not copied into the final image.

Enroll the public certificate once on the laptop:

```bash
sudo mokutil --import qc71-keys/qc71-signing.der
```

Reboot and complete **Enroll MOK** in the firmware UI.

The same public certificate is embedded in the image at:

```text
/usr/share/bluefin-slimbook/qc71-signing.der
```

### Container image signing

Generate a Cosign key pair:

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
```

Add:

- `SIGNING_SECRET`: contents of `cosign.key`

Keep `cosign.key` private. `cosign.pub` may be committed to this repository for verification.

## Switch to the image

After the first successful build:

```bash
sudo bootc switch ghcr.io/klprv/bluefin-slimbook:stable
sudo systemctl reboot
```

## Verify QC71

```bash
modinfo qc71_laptop | grep -E 'filename|signer'
systemctl status slimbook-service.service
```
