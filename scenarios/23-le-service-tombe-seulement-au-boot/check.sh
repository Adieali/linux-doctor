#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Le check redémarre le serveur deux fois. L'étape attendue est notée sur le disque, et dans /run (effacé au
# démarrage) le fait que le redémarrage n'a pas encore eu lieu.
etape=/var/lib/labo-check/23-etape
avant=/run/labo-check-23
vip=10.100.0.100

client() { ip netns exec client "$@"; }
vip_sur() { if [[ $1 == srv-prod-01 ]]; then ip -br addr show eth1; else ip -n "$1" -br addr show eth1; fi | grep -q "$vip/"; }
attendre_vip() { for _ in {1..60}; do vip_sur "$1" && return; sleep 0.25; done; return 1; }
nginx_tourne() { [[ $(systemctl show -p ActiveState --value nginx) == active ]]; }
boutique() { [[ $(client curl -s --max-time 3 "http://$vip/") == *srv-prod-01* ]]; }
page_etat() { client curl -fs --max-time 3 http://10.100.0.21:8080/etat | grep -q 'Active connections'; }
rien_sur_le_noeud() { ! client curl -s -o /dev/null --max-time 3 http://10.100.0.21/; }
bascule() { timeout 5 bash -c "until ip netns exec client curl -s --max-time 1 http://$vip/ | grep -q srv-prod-01; do sleep 0.2; done"; }
redemarrer() { mkdir -p "${etape%/*}"; echo "$1" > "$etape"; touch "$avant"; exit 3; }

phase=0
[[ -f $etape && ! -f $avant ]] && phase=$(cat "$etape")
rm -f "$etape"

case $phase in
  0)
    ok "nginx tourne" nginx_tourne
    ok "un client charge la boutique par la VIP" boutique
    ok "la page d'état de la supervision répond sur l'adresse du nœud" page_etat
    ok "la boutique ne répond pas sur l'adresse propre du nœud (audit)" rien_sur_le_noeud
    (( fail )) && exit 1
    redemarrer 1
    ;;
  1)
    echo "  srv-prod-01 a redémarré :"
    attendre_vip srv-prod-01
    timeout 10 bash -c 'until systemctl is-active -q nginx; do sleep 0.5; done'   # un délai de relance a sa chance
    ok "srv-prod-01 a repris la VIP" vip_sur srv-prod-01
    ok "nginx tourne" nginx_tourne
    ok "un client charge la boutique par la VIP" boutique
    ok "la page d'état répond" page_etat
    ok "la boutique ne répond pas sur l'adresse propre du nœud" rien_sur_le_noeud
    (( fail )) && exit 1
    # Au prochain démarrage, srv-prod-01 sera le nœud de secours : srv-prod-02 passe en priorité 200.
    sed -i 's/priority 100/priority 200/' /etc/keepalived/srv-prod-02.conf
    redemarrer 2
    ;;
  2)
    # srv-prod-02 a lu sa priorité 200 au démarrage ; le fichier reprend sa valeur pour la suite.
    sed -i 's/priority 200/priority 100/' /etc/keepalived/srv-prod-02.conf
    echo "  srv-prod-01 a redémarré en nœud de secours (srv-prod-02 en priorité 200) :"
    attendre_vip srv-prod-02
    sleep 5   # le temps qu'un nginx qui ne peut pas démarrer abandonne, ou tourne en boucle
    ok "srv-prod-02 a la VIP" vip_sur srv-prod-02
    ok "nginx tourne sur srv-prod-01, sans la VIP" nginx_tourne
    ok "la page d'état de srv-prod-01 répond" page_etat
    echo "  srv-prod-02 tombe :"
    systemctl stop lab-keepalived-02
    ok "srv-prod-01 sert la boutique moins de 5 s plus tard" bascule
    systemctl start lab-keepalived-02
    exit $fail
    ;;
esac
