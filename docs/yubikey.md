# YubiKey

## OpenPGP

Use `pcscd` with GnuPG instead of the direct CCID backend.

```bash
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg

cat > ~/.gnupg/scdaemon.conf <<'EOF'
disable-ccid
pcsc-shared
EOF

chmod 600 ~/.gnupg/scdaemon.conf

gpgconf --kill scdaemon
gpgconf --kill gpg-agent
```

Verify:

```bash
gpg --card-status
```

## SSH

For hosts using a FIDO2 SSH key, configure OpenSSH to bypass the SSH agent.

Example `~/.ssh/config`:

```sshconfig
Host myserver
    HostName server.example.com
    User user
    IdentityFile ~/.ssh/id_ed25519_sk
    IdentitiesOnly yes
    IdentityAgent none
```

For a one-off connection:

```bash
SSH_AUTH_SOCK=none ssh user@server
```