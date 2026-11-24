#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

serveur=10.80.0.10
# Depuis le poste d'audit, comme le contre-audit de l'équipe sécurité.
depuis_audit() { ip netns exec audit ssh -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/opt/labo/audit/known_hosts "$@" 2>&1; }

sshd_valide() { sshd -t </dev/null && systemctl is-active -q ssh; }
admin_par_cle() { ip netns exec bastion ssh -o BatchMode=yes -o ConnectTimeout=5 "admin@$serveur" true; }
root_refuse() { ! ip netns exec bastion ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$serveur" true; }
cle_seulement() {
  local methodes
  methodes=$(depuis_audit -v -o PreferredAuthentications=none -i /opt/labo/audit/id_ed25519 "admin@$serveur" true \
    | grep -m1 'Authentications that can continue:')
  [[ $methodes == *publickey* && $methodes != *password* && $methodes != *keyboard-interactive* ]]
}
kex_sha1_refuse() { depuis_audit -o KexAlgorithms=diffie-hellman-group14-sha1 "admin@$serveur" true | grep -q 'no matching key exchange'; }
mac_sha1_refuse() {
  depuis_audit -o Ciphers=aes128-ctr -o MACs=hmac-sha1 "admin@$serveur" true | grep -q 'no matching MAC' &&
    depuis_audit -o Ciphers=aes128-ctr -o MACs=hmac-sha1-etm@openssh.com "admin@$serveur" true | grep -q 'no matching MAC'
}
# La clé d'edi, présentée en ssh-rsa depuis le poste d'audit : hors de la dérogation.
ssh_rsa_hors_derogation() {
  ! echo pwd | ip netns exec audit sftp -q -b - -i /opt/labo/transporteur/edi_rsa -o BatchMode=yes -o ConnectTimeout=5 \
    -o UserKnownHostsFile=/opt/labo/audit/known_hosts -o PubkeyAcceptedAlgorithms=ssh-rsa "edi@$serveur"
}
# Pour les autres comptes, même depuis l'adresse du transporteur : ce que sshd appliquerait.
ssh_rsa_autres_comptes() {
  local c
  for c in user=admin,addr=10.80.0.15 user=admin,addr=10.80.0.99 user=edi,addr=10.80.0.99; do
    sshd -T -C "$c,host=x" </dev/null | grep '^pubkeyacceptedalgorithms ' | tr ', ' '\n' | grep -qx ssh-rsa && return 1
  done
  return 0
}
transporteur_passe() { /usr/local/bin/transporteur envoi; }
# Une clé inconnue présentée pour admin : son empreinte doit apparaître dans le journal.
cle_refusee_journalisee() {
  local empreinte debut
  empreinte=$(ssh-keygen -lf /opt/labo/audit/id_ed25519.pub | awk '{print $2}')
  debut=$(date +%s)
  depuis_audit -i /opt/labo/audit/id_ed25519 "admin@$serveur" true >/dev/null
  sleep 1
  journalctl --no-pager -q --since "@$debut" -u ssh | grep -qF "$empreinte"
}

ok "la configuration de sshd est valide, et sshd tourne" sshd_valide
ok "admin se connecte depuis le bastion, par clé" admin_par_cle
ok "seule l'authentification par clé est proposée" cle_seulement
ok "root ne se connecte pas, même avec la clé du bastion" root_refuse
ok "l'échange de clés diffie-hellman-group14-sha1 est refusé" kex_sha1_refuse
ok "les MAC hmac-sha1 et hmac-sha1-etm sont refusés" mac_sha1_refuse
ok "ssh-rsa est refusé pour edi depuis une autre adresse que celle du transporteur" ssh_rsa_hors_derogation
ok "ssh-rsa n'est accepté pour aucun autre compte" ssh_rsa_autres_comptes
ok "le transporteur dépose toujours ses bons de livraison" transporteur_passe
ok "une clé refusée laisse son empreinte dans le journal" cle_refusee_journalisee

exit $fail
