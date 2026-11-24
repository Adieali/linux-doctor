#!/usr/bin/env bash
# Panne : le changement PAM de la sécurité (SEC-118, hier soir) a fermé la porte aux admins, de deux façons.
# 1. pam_access, dans le compte de sshd, avec l'option nodefgroup : « admins » dans access.conf ne désigne plus
#    le groupe, seulement un utilisateur qui n'existe pas. Les admins sont refusés ; la supervision, désignée par
#    son nom d'utilisateur, passe toujours.
# 2. pam_faillock : 3 échecs, verrouillage sans fin (unlock_time = 0). sshd accepte les mots de passe depuis
#    Internet, et un robot y essaie des mots de passe en boucle : alice et bruno sont verrouillés. Leur clé SSH
#    les connecte (pas de phase auth de PAM), mais sudo, qui demande leur mot de passe, est refusé.
# Pièges pour la réparation : déverrouiller (faillock --reset) ne tient pas, le robot reverrouille dans la minute ;
# retirer faillock ou pam_access est contraire à SEC-118 ; couper SSH depuis Internet coupe les prestataires.
# Fausses pistes : la supervision passe (donc « SSH marche »), les clés des admins, sudoers.
set -euo pipefail

routeur() { ip netns exec "$1" sysctl -qw net.ipv4.ip_forward=1; }
lien() { # netns adresse-hôte/masque adresse-routeur/masque interface-routeur
  ip netns add "$1"
  ip -n "$1" link set lo up
  ip -n routeur link add "$4" type veth peer name eth0 netns "$1"
  ip -n routeur addr add "$3" dev "$4"
  ip -n routeur link set "$4" up
  ip -n "$1" addr add "$2" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" route add default via "${3%/*}"
}

# Le routeur : le serveur, le bastion, la supervision, et Internet.
ip netns add routeur
ip -n routeur link set lo up
routeur routeur
ip link add eth1 type veth peer name serveurs netns routeur
ip -n routeur addr add 10.70.0.1/24 dev serveurs
ip -n routeur link set serveurs up
ip addr add 10.70.0.10/24 dev eth1
ip link set eth1 up
ip route del default 2>/dev/null || true
ip route add default via 10.70.0.1
lien bastion 10.71.0.5/24 10.71.0.1/24 vers-bastion
lien supervision 10.72.0.20/24 10.72.0.1/24 vers-superv
lien internet 203.0.113.50/24 203.0.113.1/24 wan

# Les comptes : deux admins, un développeur, la supervision. Clés sur le bastion (et la supervision).
groupadd admins
groupadd devs
install -d -m 700 /opt/labo/cles
declare -A mdp=([alice]='Hiver-Rouge-2026' [bruno]='Pont-Neuf-1789' [dev1]='Cafe-Noir-42')
for u in alice bruno dev1 supervision; do
  case $u in
    alice | bruno) useradd -m -s /bin/bash -G admins,sudo "$u" ;;
    dev1) useradd -m -s /bin/bash -G devs "$u" ;;
    supervision) useradd -m -s /bin/bash "$u" ;;
  esac
  [[ -n ${mdp[$u]:-} ]] && echo "$u:${mdp[$u]}" | chpasswd
  ssh-keygen -q -t ed25519 -N '' -C "$u" -f "/opt/labo/cles/$u"
  install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
  install -m 600 -o "$u" -g "$u" "/opt/labo/cles/$u.pub" "/home/$u/.ssh/authorized_keys"
done
printf '%s\n' "alice ${mdp[alice]}" "bruno ${mdp[bruno]}" "dev1 ${mdp[dev1]}" > /opt/labo/mots-de-passe
chmod 600 /opt/labo/mots-de-passe
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | sed 's/^127\.0\.0\.1/10.70.0.10/' > /opt/labo/known_hosts

# SEC-118, hier soir : connexions SSH réservées aux admins depuis le bastion, et à la supervision.
cat > /etc/security/access.conf <<'EOF'
# SEC-118 : connexions SSH réservées aux admins (depuis le bastion) et à la supervision.
# Format : permission:utilisateurs:origines. La première ligne qui correspond l'emporte.
+:supervision:10.72.0.20
+:admins:10.71.0.5
-:ALL:ALL
EOF
sed -i 's/^# account  required     pam_access.so$/# SEC-118 : contrôle d'\''accès par utilisateur et origine (\/etc\/security\/access.conf).\naccount    required     pam_access.so nodefgroup/' /etc/pam.d/sshd
grep -q '^account    required     pam_access.so nodefgroup' /etc/pam.d/sshd

# SEC-118 : verrouillage après 3 échecs, sans déverrouillage automatique.
cat > /etc/security/faillock.conf <<'EOF'
# SEC-118 (CIS 5.3.3.1) : 3 échecs, et le compte reste verrouillé jusqu'à un déverrouillage par un admin.
audit
deny = 3
unlock_time = 0
EOF
cat > /etc/pam.d/common-auth <<'EOF'
# SEC-118 : pam_faillock autour de pam_unix.
auth	required			pam_faillock.so preauth
auth	[success=2 default=ignore]	pam_unix.so nullok
auth	[default=die]			pam_faillock.so authfail
auth	requisite			pam_deny.so
auth	required			pam_permit.so
EOF

# Le robot d'Internet : des mots de passe au hasard, sur les comptes qu'il devine, en boucle.
install -d /opt/labo/internet
cat > /opt/labo/internet/mot-de-passe <<'EOF'
#!/bin/sh
# Labo : le robot propose un mot de passe pris dans son dictionnaire.
shuf -n1 -e azerty 123456 motdepasse Password1 admin2024 soleil Bienvenue1
EOF
chmod 755 /opt/labo/internet/mot-de-passe
cat > /opt/labo/internet/internet.sh <<'EOF'
#!/bin/bash
# Labo : un robot d'Internet qui essaie des mots de passe sur le SSH du serveur, en boucle.
while true; do
  for u in alice bruno root admin test oracle; do
    SSH_ASKPASS=/opt/labo/internet/mot-de-passe SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
      ip netns exec internet setsid -w ssh -n -o BatchMode=no -o PubkeyAuthentication=no \
      -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "$u@10.70.0.10" true \
      >/dev/null 2>&1
  done
  sleep 15
done
EOF
chmod 755 /opt/labo/internet/internet.sh
cat > /etc/systemd/system/lab-internet.service <<'EOF'
[Unit]
Description=Labo : Internet, tel qu'il est (ne pas toucher)

[Service]
ExecStart=/opt/labo/internet/internet.sh

[Install]
WantedBy=multi-user.target
EOF

# Commandes du labo : se connecter comme un des comptes, avec sa clé, depuis son poste habituel.
cat > /usr/local/bin/connexion <<'EOF'
#!/bin/bash
# Labo : connexion SSH d'un compte, avec sa clé, depuis son poste (bastion, ou supervision pour « supervision »).
#   connexion alice              un shell
#   connexion alice id           une commande
#   connexion alice sudo id      une commande avec sudo : le mot de passe est donné comme le taperait alice
[[ $# -ge 1 ]] || { echo "usage : connexion <compte> [commande]" >&2; exit 2; }
u=$1; shift
poste=bastion; [[ $u == supervision ]] && poste=supervision
ssh_opts=(-i "/opt/labo/cles/$u" -o UserKnownHostsFile=/opt/labo/known_hosts -o BatchMode=yes -o ConnectTimeout=5)
if [[ ${1:-} == sudo ]]; then
  shift
  mdp=$(awk -v u="$u" '$1 == u {print $2}' /opt/labo/mots-de-passe)
  exec ip netns exec "$poste" ssh -n "${ssh_opts[@]}" "$u@10.70.0.10" "echo '$mdp' | sudo -S -p '' $*"
fi
[[ $# -eq 0 ]] && exec ip netns exec "$poste" ssh -t "${ssh_opts[@]}" "$u@10.70.0.10"
exec ip netns exec "$poste" ssh -n "${ssh_opts[@]}" "$u@10.70.0.10" "$@"
EOF
chmod 755 /usr/local/bin/connexion

systemctl daemon-reload
systemctl restart ssh
systemctl enable --now lab-internet 2>/dev/null

# La nuit du robot : alice et bruno verrouillés. La supervision, elle, passe.
verrouille() { (( $(faillock --user "$1" | grep -c ' V$') >= 3 )); }
timeout 240 bash -c "$(declare -f verrouille); until verrouille alice && verrouille bruno; do sleep 2; done" \
  || { faillock --user alice >&2; echo "alice et bruno auraient dû être verrouillés" >&2; exit 1; }
connexion supervision true
if connexion alice true 2>/dev/null; then
  echo "alice aurait dû être refusée par pam_access" >&2
  exit 1
fi
