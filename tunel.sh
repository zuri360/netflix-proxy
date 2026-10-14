#!/usr/bin/env bash
# =====================================================================
#  tunel.sh — se ejecuta en el VPS del TÚNEL (SSH/V2Ray), NO en el proxy.
#  Desvía todas las consultas DNS (UDP y TCP) hacia el netflix-proxy.
#
#  Uso:  bash tunel.sh            -> menú
#        bash tunel.sh activar    -> activa sin menú
#        bash tunel.sh quitar     -> quita sin menú
#        bash tunel.sh estado     -> muestra estado y prueba
#        bash tunel.sh desinstalar -> revierte todo lo que hizo el script
#
#  IP del proxy: por defecto 109.199.101.86. Para otra:
#        PROXY_IP=1.2.3.4 bash tunel.sh
# =====================================================================

PROXY_IP="${PROXY_IP:-109.199.101.86}"
TEST_DOMAIN="ifconfig.co"   # viene en la lista por defecto de netflix-proxy

verde='\e[32m'; rojo='\e[31m'; amarillo='\e[33m'; negrita='\e[1m'; reset='\e[0m'
ok()    { echo -e "${verde}[ OK ]${reset} $*"; }
info()  { echo -e "${amarillo}[ .. ]${reset} $*"; }
fallo() { echo -e "${rojo}[FALLO]${reset} $*"; }

[[ $EUID -eq 0 ]] || { echo "Ejecutá como root."; exit 1; }

# Se excluye 127.0.0.0/8: si no, también se desvía el resolver local (127.0.0.53)
# y el propio VPS se queda sin poder resolver nombres.
regla()        { echo "! -d 127.0.0.0/8 -p $1 --dport 53 -j DNAT --to-destination ${PROXY_IP}:53"; }
regla_vieja()  { echo "-p $1 --dport 53 -j DNAT --to-destination ${PROXY_IP}:53"; }

limpiar_viejas() {
    for p in udp tcp; do
        while iptables -t nat -D OUTPUT $(regla_vieja $p) 2>/dev/null; do :; done
    done
}

dependencias() {
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v dig >/dev/null || ! command -v netfilter-persistent >/dev/null; then
        info "Instalando dnsutils e iptables-persistent..."
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        apt-get update -qq
        apt-get -y -qq install dnsutils iptables-persistent >/dev/null || { fallo "No se pudieron instalar los paquetes."; return 1; }
    fi
}

guardar() {
    netfilter-persistent save >/dev/null 2>&1 && ok "Reglas guardadas (sobreviven al reinicio)" \
        || fallo "No se pudieron guardar las reglas"
}

probar() {
    local udp tcp
    udp=$(dig +short +time=3 +tries=1 "$TEST_DOMAIN" @8.8.8.8 | tail -1)
    tcp=$(dig +tcp +short +time=3 +tries=1 "$TEST_DOMAIN" @8.8.8.8 | tail -1)
    [[ "$udp" == "$PROXY_IP" ]] && ok "DNS UDP -> proxy ($udp)" || fallo "DNS UDP responde: ${udp:-sin respuesta}"
    [[ "$tcp" == "$PROXY_IP" ]] && ok "DNS TCP -> proxy ($tcp)" || fallo "DNS TCP responde: ${tcp:-sin respuesta}"
}

probar_internet() {
    local r
    r=$(curl -sI --max-time 10 https://raw.githubusercontent.com | head -1 | tr -d '\r')
    if [[ -n "$r" ]]; then
        ok "Internet del VPS OK (GitHub responde: $r)"
        return 0
    else
        fallo "El VPS no puede resolver/conectar a GitHub"
        return 1
    fi
}

activar() {
    limpiar_viejas
    dependencias || return
    for p in udp tcp; do
        if iptables -t nat -C OUTPUT $(regla $p) >/dev/null 2>&1; then
            ok "Regla $p ya estaba activa"
        else
            iptables -t nat -A OUTPUT $(regla $p) && ok "Regla $p agregada"
        fi
    done

    info "Probando..."
    sleep 1
    probar

    # Si TCP no responde, se quita para no dejar el VPS sin DNS por TCP
    if ! dig +tcp +short +time=3 +tries=1 "$TEST_DOMAIN" @8.8.8.8 | grep -qx "$PROXY_IP"; then
        while iptables -t nat -D OUTPUT $(regla tcp) 2>/dev/null; do :; done
        echo -e "${amarillo}Se quitó la regla TCP porque el proxy no responde por TCP.${reset}"
        echo "En el proxy ejecutá: menu2 -> opción 1 -> la IP de este VPS"
        echo "(o: iptables -I INPUT -s IP_DE_ESTE_VPS/32 -p tcp --dport 53 -j ACCEPT)"
    fi

    # Si el VPS se quedó sin internet, se deshace todo para no dejarlo roto
    if ! probar_internet; then
        for p in udp tcp; do
            while iptables -t nat -D OUTPUT $(regla $p) 2>/dev/null; do :; done
        done
        echo -e "${amarillo}Se quitaron las reglas para no dejar el VPS sin internet. Revisá el proxy.${reset}"
    fi
    guardar
}

quitar() {
    limpiar_viejas
    for p in udp tcp; do
        local n=0
        while iptables -t nat -D OUTPUT $(regla $p) 2>/dev/null; do n=$((n+1)); done
        [[ $n -gt 0 ]] && ok "Regla $p quitada" || info "Regla $p no estaba activa"
    done
    command -v netfilter-persistent >/dev/null && guardar
    echo "El DNS de este VPS volvió a la normalidad."
}

estado() {
    echo -e "${negrita}Proxy configurado:${reset} $PROXY_IP"
    for p in udp tcp; do
        iptables -t nat -C OUTPUT $(regla $p) >/dev/null 2>&1 \
            && echo -e " ${verde}●${reset} Regla $p activa" || echo -e " ${rojo}●${reset} Regla $p inactiva"
    done
    command -v dig >/dev/null && { echo; probar; }
    probar_internet
}

desinstalar() {
    echo -e "${negrita}Esto revierte todo lo que hizo tunel.sh en este VPS:${reset}"
    echo " - Quita las reglas DNAT de DNS (nuevas y viejas, UDP y TCP)"
    echo " - Guarda el firewall sin esas reglas"
    echo " - Opcional: desinstala iptables-persistent y dnsutils"
    read -rp "¿Continuar? (s/n): " r
    [[ "$r" =~ ^[sS]$ ]] || { echo "Cancelado."; return; }

    # 1) Reglas nuevas (con exclusión de loopback) y viejas (sin exclusión)
    local n=0
    for p in udp tcp; do
        while iptables -t nat -D OUTPUT $(regla $p) 2>/dev/null; do n=$((n+1)); done
        while iptables -t nat -D OUTPUT $(regla_vieja $p) 2>/dev/null; do n=$((n+1)); done
    done
    ok "Reglas DNAT quitadas: $n"

    # 2) Guardar el firewall limpio
    if command -v netfilter-persistent >/dev/null; then
        guardar
    fi

    # 3) Paquetes instalados por el script (opcional)
    read -rp "¿Desinstalar también iptables-persistent y dnsutils? (s/n): " r2
    if [[ "$r2" =~ ^[sS]$ ]]; then
        echo -e "${amarillo}Ojo: sin iptables-persistent, ninguna regla de firewall se restaura al reiniciar.${reset}"
        read -rp "¿Seguro? (s/n): " r3
        if [[ "$r3" =~ ^[sS]$ ]]; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get -y -qq remove iptables-persistent netfilter-persistent dnsutils >/dev/null 2>&1 \
                && ok "Paquetes desinstalados" || fallo "No se pudieron desinstalar los paquetes"
        fi
    fi

    # 4) Comprobar que el VPS resuelve normal
    probar_internet
    echo -e "${verde}Desinstalación completa. El DNS de este VPS volvió a la normalidad.${reset}"
    echo "Recordá quitar la IP de este VPS en el proxy: menu2 -> opción 3."
}

case "$1" in
    activar) activar; exit ;;
    quitar)  quitar;  exit ;;
    estado)  estado;  exit ;;
    desinstalar) desinstalar; exit ;;
esac

while true; do
    clear
    echo -e "${negrita}====== TÚNEL -> NETFLIX-PROXY ======${reset}"
    echo " Proxy DNS: $PROXY_IP"
    echo "------------------------------------"
    echo " 1) Activar (UDP + TCP) y guardar"
    echo " 2) Quitar reglas"
    echo " 3) Estado y prueba"
    echo " 4) Desinstalar"
    echo " 0) Salir"
    echo "------------------------------------"
    read -rp "Opción: " op
    echo
    case $op in
        1) activar ;;
        2) quitar ;;
        3) estado ;;
        4) desinstalar ;;
        0) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
    echo; read -rp "Enter para volver al menú..." _
done
