# Bluefin Slimbook

Bluefin DX image for the Slimbook Executive 14 UC2.

Based on `ghcr.io/ublue-os/bluefin-dx:stable`.

## Included

- `qc71_laptop`, built for the exact Bluefin kernel
- Slimbook Service and its runtime dependencies
- QC71 module signing for Secure Boot
- Slimbook system branding

## Installation

From Bluefin DX:

```bash
sudo bootc switch ghcr.io/klprv/bluefin-slimbook:stable
sudo reboot
```

## Secure Boot

Ensure the Universal Blue Secure Boot key is enrolled:

```bash
ujust enroll-secure-boot-key
```

Enroll the QC71 signing certificate:

```bash
sudo mokutil --import /usr/share/bluefin-slimbook/qc71-signing.der
sudo reboot
```

In MOK Manager, select `Enroll MOK`, confirm the certificate, enter the temporary password, and reboot. Secure Boot can then be enabled in the firmware settings.