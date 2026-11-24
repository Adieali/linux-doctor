#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

serveur=10.70.0.10
connexion() { /usr/local/bin/connexion "$@"; }
depuis_internet() { ip netns exec internet ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/opt/labo/known_hosts "$@" 2>&1; }

sec118() {
  grep -Eq '^\s*account\s+required\s+pam_access\.so' /etc/pam.d/sshd &&
    grep -Eq '^\s*auth\s+required\s+pam_faillock\.so\s+preauth' /etc/pam.d/common-auth &&
    grep -Eq '^\s*auth\s+\S+\s+pam_faillock\.so\s+authfail' /etc/pam.d/common-auth &&
    grep -Eq '^\s*-:ALL:ALL' /etc/security/access.conf
}
admin() { connexion "$1" sudo true; }
refuse() { ! connexion "$1" true; }
alice_hors_bastion() { ! depuis_internet -i /opt/labo/cles/alice "alice@$serveur" true; }
cle_depuis_internet() { depuis_internet -v -o PreferredAuthentications=none "alice@$serveur" true | grep -q 'Authentications that can continue: publickey'; }
pas_de_mot_de_passe_depuis_internet() {
  local t
  t=$(sshd -T -C user=alice,addr=203.0.113.50,host=x </dev/null)
  grep -qx 'passwordauthentication no' <<<"$t" && grep -qx 'kbdinteractiveauthentication no' <<<"$t"
}
rafale() { # des mots de passe faux depuis Internet, comme le robot, mais 3 par compte d'un coup
  local u
  for u in alice bruno; do
    for _ in 1 2 3; do
      SSH_ASKPASS=/opt/labo/internet/mot-de-passe SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ip netns exec internet setsid -w ssh -n -o BatchMode=no -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "$u@$serveur" true >/dev/null 2>&1
    done
  done
}
aucun_echec() { (( $(faillock --user "$1" | grep -c ' V$') == 0 )); }
# Le verrouillage marche toujours : trois mauvais mots de passe pour dev1, en local, à sudo.
verrouillage() {
  faillock --user dev1 --reset
  for _ in 1 2 3; do echo faux | runuser -u dev1 -- sudo -S -k -p '' true >/dev/null 2>&1; done
  (( $(faillock --user dev1 | grep -c ' V$') >= 3 ))
  local rc=$?
  faillock --user dev1 --reset
  return "$rc"
}

ok "SEC-118 en place : pam_access pour sshd, pam_faillock autour de pam_unix" sec118
ok "alice se connecte depuis le bastion, et sudo marche" admin alice
ok "bruno aussi" admin bruno
ok "la supervision se connecte toujours" connexion supervision true
ok "dev1, qui n'est pas admin, est refusé" refuse dev1
ok "alice est refusée ailleurs qu'au bastion, même avec sa clé" alice_hors_bastion
ok "SSH reste joignable depuis Internet, par clé (prestataires)" cle_depuis_internet
ok "depuis Internet, sshd ne demande plus de mot de passe" pas_de_mot_de_passe_depuis_internet
ok "le verrouillage marche toujours (3 échecs de dev1 à sudo)" verrouillage
(( fail )) && exit 1

echo "  Le robot d'Internet insiste : 3 mots de passe faux pour alice et pour bruno."
rafale
ok "aucun échec compté pour alice" aucun_echec alice
ok "alice a toujours sudo" admin alice
ok "bruno a toujours sudo" admin bruno

exit $fail
