#!/usr/bin/env bash
# Situation : l'audit exige de durcir sshd, et le transporteur dépose ses bons de livraison en SFTP avec un client
# qui ne signe qu'en ssh-rsa (SHA-1). Pièges :
# 1. sshd garde la première valeur lue pour chaque directive, et les fichiers de sshd_config.d sont lus dans
#    l'ordre : un 99-audit.conf ne change rien à ce que 40-transporteur.conf ou 50-cloud-init.conf ont déjà fixé.
# 2. ssh-rsa peut être limité au compte edi depuis l'adresse du transporteur (Match), mais KexAlgorithms, MACs et
#    Ciphers ne se règlent pas dans un Match. Le fichier de 2019 ajoute aussi l'échange de clés et le MAC en SHA-1
#    « au cas où » : le client du transporteur n'en a pas besoin (il négocie ecdh-sha2-nistp256 et hmac-sha2-256).
# 3. hmac-sha1 est proposé par défaut par OpenSSH : il faut le retirer explicitement.
# 4. La clé du bastion est aussi dans /root/.ssh/authorized_keys : PermitRootLogin par défaut l'accepte.
# Fausses pistes : la clé RSA d'edi (elle est bonne, c'est l'algorithme de signature), le pare-feu.
set -euo pipefail

# Le LAN : le serveur, le bastion des admins, le poste d'audit, et le serveur SFTP du transporteur (10.80.0.15).
ip netns add lan
ip -n lan link add br0 type bridge
ip -n lan link set br0 up
ip link add eth1 type veth peer name p-srv netns lan
ip -n lan link set p-srv master br0 up
ip addr add 10.80.0.10/24 dev eth1
ip link set eth1 up
poste() { # netns adresse
  ip netns add "$1"
  ip -n lan link add "p-$1" type veth peer name eth0 netns "$1"
  ip -n lan link set "p-$1" master br0 up
  ip -n "$1" link set lo up
  ip -n "$1" addr add "$2/24" dev eth0
  ip -n "$1" link set eth0 up
}
poste bastion 10.80.0.5
poste audit 10.80.0.99
poste transporteur 10.80.0.15

# Les clés : celle des admins sur le bastion, celle du transporteur (RSA, son client ne connaît que ça).
install -d -m 700 /opt/labo/bastion /opt/labo/transporteur /opt/labo/audit
ssh-keygen -q -t ed25519 -N '' -C 'admin@bastion' -f /opt/labo/bastion/id_ed25519
ssh-keygen -q -t rsa -b 3072 -N '' -C 'edi@transporteur' -f /opt/labo/transporteur/edi_rsa
ssh-keygen -q -t ed25519 -N '' -C 'scanner@audit' -f /opt/labo/audit/id_ed25519
for poste in bastion transporteur audit; do
  ssh-keyscan -t ed25519,rsa,ecdsa 127.0.0.1 2>/dev/null | sed 's/^127\.0\.0\.1/10.80.0.10/' > "/opt/labo/$poste/known_hosts"
done

# admin : clé du bastion, et un mot de passe que l'audit a trouvé par dictionnaire.
useradd -m -s /bin/bash -G sudo admin
echo 'admin:Bienvenue2024!' | chpasswd
install -d -m 700 -o admin -g admin /home/admin/.ssh
install -m 600 -o admin -g admin /opt/labo/bastion/id_ed25519.pub /home/admin/.ssh/authorized_keys
install -d -m 700 /root/.ssh
cp /opt/labo/bastion/id_ed25519.pub /root/.ssh/authorized_keys

# edi : le dépôt SFTP du transporteur, enfermé dans son dossier.
useradd -M -d /depot -s /usr/sbin/nologin edi
install -d -m 755 /srv/sftp/edi
install -d -m 755 -o edi -g edi /srv/sftp/edi/depot
install -d -m 755 /etc/ssh/cles-autorisees
install -m 644 /opt/labo/transporteur/edi_rsa.pub /etc/ssh/cles-autorisees/edi

cat > /etc/ssh/sshd_config.d/40-transporteur.conf <<'EOF'
# Transporteur (ticket #2231, 2019) : dépôt SFTP des bons de livraison, compte edi, depuis 10.80.0.15.
# Leur client est une vieille bibliothèque Java : d'après leur documentation, « algorithmes SHA-1 requis ».
PubkeyAcceptedAlgorithms +ssh-rsa
KexAlgorithms +diffie-hellman-group14-sha1
MACs +hmac-sha1

Match User edi
    AuthorizedKeysFile /etc/ssh/cles-autorisees/%u
    ChrootDirectory /srv/sftp/edi
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<'EOF'
PasswordAuthentication yes
EOF
touch -d '2019-03-12' /etc/ssh/sshd_config.d/40-transporteur.conf
touch -d '2023-06-02' /etc/ssh/sshd_config.d/50-cloud-init.conf

cat > /root/audit-ssh.txt <<'EOF'
Audit de sécurité, novembre 2026 : srv-prod-01 (10.80.0.10), port 22.
Contre-audit par l'équipe sécurité depuis 10.80.0.99 avant le 30 novembre.

1. Authentification par mot de passe acceptée. Le mot de passe du compte admin a été trouvé par dictionnaire.
2. Connexion de root possible par clé : la clé du bastion est dans /root/.ssh/authorized_keys.
3. Algorithmes SHA-1 proposés :
   - échange de clés : diffie-hellman-group14-sha1
   - MAC : hmac-sha1, hmac-sha1-etm@openssh.com
   - signature de clé publique : ssh-rsa
4. Journalisation insuffisante : les clés refusées ne laissent aucune trace. Attendu : LogLevel VERBOSE,
   pour journaliser l'empreinte de chaque clé présentée.

Dérogation SEC-112 : ssh-rsa reste toléré pour le compte edi, depuis 10.80.0.15 seulement, jusqu'à la mise à
jour du client du transporteur (deuxième trimestre 2027). Aucune autre exception.
EOF

# Commandes du labo.
cat > /usr/local/bin/bastion <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis le bastion des admins (10.80.0.5), avec la clé des admins.
exec ip netns exec bastion "$@"
EOF
cat > /usr/local/bin/transporteur <<'EOF'
#!/bin/bash
# Labo : le transporteur (10.80.0.15). « transporteur envoi » dépose un bon de livraison, exactement comme leur
# client : signature ssh-rsa seulement, et les seuls algorithmes que connaît leur bibliothèque.
if [[ $1 == envoi ]]; then
  bon=$(mktemp /tmp/bon-XXXXXX.csv)
  echo "bon;$(date +%s);livré" > "$bon"
  echo "put $bon" | ip netns exec transporteur sftp -q -b - -i /opt/labo/transporteur/edi_rsa \
    -o UserKnownHostsFile=/opt/labo/transporteur/known_hosts -o BatchMode=yes -o ConnectTimeout=5 \
    -o PubkeyAcceptedAlgorithms=ssh-rsa -o KexAlgorithms=ecdh-sha2-nistp256,diffie-hellman-group14-sha1 \
    -o MACs=hmac-sha2-256,hmac-sha1 -o Ciphers=aes128-ctr,aes256-ctr \
    -o HostKeyAlgorithms=rsa-sha2-256,ecdsa-sha2-nistp256 edi@10.80.0.10:/depot
  rc=$?
  rm -f "$bon"
  exit $rc
fi
exec ip netns exec transporteur "$@"
EOF
cat > /usr/local/bin/audit <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis le poste de l'équipe sécurité (10.80.0.99).
exec ip netns exec audit "$@"
EOF
chmod +x /usr/local/bin/bastion /usr/local/bin/transporteur /usr/local/bin/audit
cat > /root/.ssh/config <<'EOF'
# Labo : depuis le bastion, la clé des admins.
Host 10.80.0.10
    IdentityFile /opt/labo/bastion/id_ed25519
    UserKnownHostsFile /opt/labo/bastion/known_hosts
EOF

systemctl restart ssh
timeout 10 bash -c 'until transporteur envoi 2>/dev/null; do sleep 0.5; done'
bastion ssh -o BatchMode=yes admin@10.80.0.10 true
