# linux-scripts

Small admin scripts for Ubuntu servers.

| Script | What it does |
|---|---|
| [`create-user`](create-user/create-user.sh) | Creates a user with SSH key login and, optionally, passwordless sudo |

## create-user

Creates a Linux user without a password, adds their SSH public key to
`~/.ssh/authorized_keys` with the right permissions, and grants passwordless
sudo through `/etc/sudoers.d/<name>`. The sudoers rule is checked with
`visudo` before it is installed.

### Install

```bash
git clone git@github.com:pwrzeszcz-ep/linux-scripts.git
cd linux-scripts
sudo ./create-user/create-user.sh --install   # installs /usr/local/bin/create-user
```

You can also run `./create-user/create-user.sh` straight from the clone. When
not run as root, the script restarts itself with `sudo`.

### Usage

```bash
create-user                                    # interactive: asks for name, email and key
create-user -name jdoe -email jdoe@example.com -key AAAAC3NzaC1lZDI1NTE5AAAA...
create-user -name jdoe -email jdoe@example.com -key "$(cat id_ed25519.pub)" -y
create-user -name jdoe -email jdoe@example.com -key AAAA... --no-sudo
create-user -name jdoe -email jdoe@example.com -key AAAA... --dry-run
create-user --help
```

| Option | Description |
|---|---|
| `-name NAME` | Linux user name: a lowercase letter, then lowercase letters, digits, `_` or `-`, at most 32 characters |
| `-email EMAIL` | Email address, used as the key comment |
| `-key KEY` | The base64 part of an ed25519 public key, or a full public key line (`TYPE BASE64 [comment]`) of any type, used as-is |
| `-y` | Answer "yes" when the user already exists. Needed when no terminal is attached, for example in cron or CI |
| `--no-sudo` | Don't grant sudo. For an existing user, removes the access instead (see below) |
| `--dry-run` | Check the input and print the commands without running them. Doesn't need root |
| `--install` | Install the script as `/usr/local/bin/create-user` for all users |
| `-h`, `--help` | Show the help |

`-name`, `-email` and `-key` must be given together. If any of them is missing
or invalid, the script prints an error and the help text, then exits with
code 1. With none of them, it runs in interactive mode and asks again after an
invalid answer. The key is checked with `ssh-keygen`, so a made-up key is
rejected.

### Running it again for the same user

If the user already exists, the script asks `Continue and grant it passwordless
sudo? [Y/n]` (or `... revoke its sudo access? [Y/n]` with `--no-sudo`), or
carries on straight away with `-y`. It then skips `adduser` and:

- **adds the key** to `authorized_keys` only if it isn't there yet, keeping the user's other keys;
- **without `--no-sudo`**, grants sudo access;
- **with `--no-sudo`**, revokes sudo access: it deletes `/etc/sudoers.d/<name>`
  and removes the user from the `sudo`, `admin` and `wheel` groups. If another
  rule, for example in `/etc/sudoers`, still gives the user sudo, the script
  warns about it but doesn't edit that file. Leaving a group only takes effect
  at the user's next login. It refuses to revoke sudo from the user running
  the script, so you can't lock yourself out.

The script refuses to change a `.ssh` directory or `authorized_keys` file that
is a symlink.

### Tests

```bash
./create-user/create-user.test.sh          # input checks and dry runs, no root needed
./create-user/create-user.test.sh --real   # also creates and deletes throwaway users (needs sudo)
```

`--real` uses the users `zz_test_user`, `zz_test_old` and `zz_test_nosudo`
and the group `sudo-zztest`, and refuses to run if any of them already exists.

### Requirements

Ubuntu or Debian with bash, `adduser`, `sudo`, `visudo` and `ssh-keygen`.
Tested on Ubuntu with adduser 3.153 and OpenSSH 10.2.
