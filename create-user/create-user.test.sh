#!/usr/bin/env bash
# Tests for create-user.sh. Input/dry-run cases need no root; pass --real to
# also create and delete throwaway users (needs sudo).
set -u
S=$(dirname "$(readlink -f "$0")")/create-user.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ssh-keygen -q -t ed25519 -N '' -C x -f "$T/k"
ssh-keygen -q -t ecdsa -N '' -C ec -f "$T/e"
KEY=$(cut -d' ' -f2 "$T/k.pub")
EC_BODY=$(cut -d' ' -f2 "$T/e.pub")
pass=0 failn=0
check() { # desc, expected exit, grep pattern, cmd...
  local d=$1 e=$2 p=$3; shift 3
  out=$("$@" 2>&1 </dev/null); rc=$?
  if [[ $rc == "$e" ]] && grep -q -- "$p" <<<"$out"; then ((pass++)); else ((failn++)); echo "FAIL: $d (rc=$rc)"; echo "$out" | head -5; fi
}
D=(-email a@b.c --dry-run)
check 'help'              0 'Parameters:'          "$S" --help
check 'missing key'       1 'must all be given'    "$S" -name a -email a@b.c --dry-run
check 'help on error'     1 'Parameters:'          "$S" -name a --dry-run
check 'no value'          1 '-email requires'      "$S" -name a -email -key x --dry-run
check 'unknown param'     1 'unknown parameter'    "$S" --foo
check 'bad name'          1 'invalid user name'    "$S" -name Bad.Name -key "$KEY" "${D[@]}"
check 'leading _'         1 'invalid user name'    "$S" -name _a -key "$KEY" "${D[@]}"
check 'bad email'         1 'invalid email'        "$S" -name a -email nope -key "$KEY" --dry-run
check 'bad key'           1 'invalid SSH'          "$S" -name a -key AAAAgarbage "${D[@]}"
check 'ecdsa body alone'  1 'invalid SSH'          "$S" -name a -key "$EC_BODY" "${D[@]}"
check 'type mismatch'     1 'invalid SSH'          "$S" -name a -key "ssh-ed25519 $EC_BODY ec" "${D[@]}"
check 'dry run'           0 "ssh-ed25519 $KEY a@b.c" "$S" -name zz_dry -key "$KEY" "${D[@]}"
check 'dry run quoting'   0 "--gecos '' zz_dry"    "$S" -name zz_dry -key "$KEY" "${D[@]}"
check 'full key line'     0 "append.*$KEY x"       "$S" -name zz_dry -key "$(cat "$T/k.pub")" "${D[@]}"
check 'ecdsa full line'   0 "append.*$EC_BODY ec"  "$S" -name zz_dry -key "$(cat "$T/e.pub")" "${D[@]}"
check 'sudo by default'   0 'visudo'               "$S" -name zz_dry -key "$KEY" "${D[@]}"
check 'no-sudo: no visudo' 1 ''                    bash -c "'$S' -name zz_dry -key '$KEY' ${D[*]} --no-sudo | grep -q 'visudo\|install'"
check 'no-sudo: revoke'   0 'rm -f /etc/sudoers.d/zz_dry' "$S" -name zz_dry -key "$KEY" "${D[@]}" --no-sudo
check 'no self-revoke'    1 'refusing to revoke'   env SUDO_USER=root "$S" -name root -key "$KEY" "${D[@]}" -y --no-sudo
check 'no-sudo interactive' 0 'chown'              bash -c "printf 'zz_dry\na@b.c\n%s\n' '$KEY' | '$S' --dry-run --no-sudo"
check 'install dry run'   0 'install -m 755'       "$S" --install --dry-run
check 'interactive EOF'   1 'no input'             "$S" --dry-run
check 'interactive ok'    0 "append.*$KEY a@b.c"   bash -c "printf 'Bad\nzz_dry\nnope\na@b.c\njunk\n%s\n' '$KEY' | '$S' --dry-run"
check 'interactive retry' 0 'Invalid email'        bash -c "printf 'zz_dry\nnope\na@b.c\n%s\n' '$KEY' | '$S' --dry-run"
check 'existing, no'      1 'Aborted'              bash -c "printf 'n\n' | '$S' -name root -key '$KEY' ${D[*]}"
check 'existing, EOF'     1 'use -y'               "$S" -name root -key "$KEY" "${D[@]}"
check 'existing, -y'      0 'append to /root/'     "$S" -name root -key "$KEY" "${D[@]}" -y

if [[ ${1:-} == --real ]]; then
  for u in zz_test_user zz_test_old zz_test_nosudo; do id $u >/dev/null 2>&1 && { echo "$u already exists, refusing --real"; exit 1; }; done
  N=zz_test_nosudo
  check 'no-sudo create' 0 'no sudo access'      sudo "$S" -name $N -email a@b.c -key "$KEY" --no-sudo
  check 'no-sudo file'   1 ''                    sudo test -e /etc/sudoers.d/$N
  check 'no-sudo denied' 1 ''                    sudo -u $N sudo -n whoami
  check 'no-sudo key ok' 0 '^1$'                 sudo grep -c "$KEY" /home/$N/.ssh/authorized_keys
  check 'rerun grants'   0 'Done:.*without a password' sudo "$S" -name $N -email a@b.c -key "$KEY" -y
  check 'granted works'  0 '^root$'              sudo -u $N sudo -n whoami
  sudo usermod -aG sudo $N
  check 'rerun revokes'  0 'no sudo access'      sudo "$S" -name $N -email a@b.c -key "$KEY" -y --no-sudo
  check 'revoked file'   1 ''                    sudo test -e /etc/sudoers.d/$N
  check 'revoked group'  1 ''                    bash -c "id -nG $N | grep -qw sudo"
  check 'revoked denied' 1 ''                    sudo -u $N sudo -n whoami
  check 'no warning'     0 ''                    bash -c "out=\$(sudo '$S' -name $N -email a@b.c -key '$KEY' -y --no-sudo 2>&1) && grep -q 'no sudo access' <<<\"\$out\" && ! grep -q Warning <<<\"\$out\""
  sudo groupadd sudo-zztest && sudo usermod -aG sudo-zztest $N  # lookalike name must be left alone
  check 'lookalike grp'  0 'no sudo access'      sudo "$S" -name $N -email a@b.c -key "$KEY" -y --no-sudo
  check 'lookalike kept' 0 'sudo-zztest'         id -nG $N
  sudo groupdel sudo-zztest
  echo "$N ALL=(ALL) ALL" | sudo tee /etc/sudoers.d/zz_other >/dev/null  # a rule the script does not own
  check 'warns on other' 0 'still has sudo rules' sudo "$S" -name $N -email a@b.c -key "$KEY" -y --no-sudo
  sudo rm -f /etc/sudoers.d/zz_other
  sudo deluser --remove-home $N >/dev/null 2>&1
  U=zz_test_user
  check 'real create'   0 'Done:'                sudo "$S" -name $U -email a@b.c -key "$KEY"
  check 'rerun -y'      0 'Done:'                sudo "$S" -name $U -email other@b.c -key "$KEY" -y
  check 'key once'      0 '^1$'                  sudo grep -c "$KEY" /home/$U/.ssh/authorized_keys
  check 'perms'         0 '700 zz_test_user 600 zz_test_user 440' \
        sudo bash -c "stat -c '%a %U' /home/$U/.ssh /home/$U/.ssh/authorized_keys | tr '\n' ' '; stat -c %a /etc/sudoers.d/$U"
  check 'sudo works'    0 '^root$'               sudo -u $U sudo -n whoami
  # existing user: group not named after user, authorized_keys without final newline
  O=zz_test_old
  sudo useradd -m -g users $O
  sudo -u $O bash -c "mkdir -p ~/.ssh && printf %s '$(cat "$T/e.pub")' > ~/.ssh/authorized_keys"  # $T is not readable by $O
  check 'existing user' 0 'Done:'                sudo "$S" -name $O -email a@b.c -key "$KEY" -y
  check 'both keys ok'  0 '^2$'                  bash -c "sudo ssh-keygen -l -f /home/$O/.ssh/authorized_keys | wc -l"
  check 'group kept'    0 'zz_test_old:users'    sudo stat -c '%U:%G' /home/$O/.ssh/authorized_keys
  for u in $U $O; do sudo deluser --remove-home $u >/dev/null 2>&1; sudo rm -f /etc/sudoers.d/$u; done
fi
echo "passed: $pass, failed: $failn"; ((failn == 0))
