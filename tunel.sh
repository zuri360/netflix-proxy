#!/usr/bin/env bash
# =====================================================================
#  tunel.sh — se ejecuta en el VPS del TÚNEL (SSH/V2Ray), NO en el proxy.
#  Desvía todas las consultas DNS (UDP y TCP) hacia el netflix-proxy.
#
#  La primera vez se instala solo en /root/tunel.sh y crea el comando: dns
#
#  Uso:  dns  (o bash tunel.sh)     -> menú
#        bash tunel.sh activar     -> activa sin menú (usa la IP guardada)
#        bash tunel.sh quitar      -> quita las reglas
#        bash tunel.sh estado      -> muestra estado y prueba
#        bash tunel.sh desinstalar -> revierte todo lo que hizo el script
#
#  La IP del proxy se pregunta en "Activar" y se guarda en /etc/tunel-proxy.conf
#  Sin menú se puede indicar así:  PROXY_IP=1.2.3.4 bash tunel.sh activar
# =====================================================================

CONF=/etc/tunel-proxy.conf
DEFAULT_PROXY="109.199.101.86"
TEST_DOMAIN="ifconfig.co"   # viene en la lista por defecto de netflix-proxy

# IP del proxy: 1) variable PROXY_IP  2) la última guardada  3) la de por defecto
GUARDADA=""
[[ -f $CONF ]] && GUARDADA=$(grep -oP '^PROXY_IP=\K.*' "$CONF")
PROXY_IP="${PROXY_IP:-${GUARDADA:-$DEFAULT_PROXY}}"

verde='\e[32m'; rojo='\e[31m'; amarillo='\e[33m'; negrita='\e[1m'; reset='\e[0m'
ok()    { echo -e "${verde}[ OK ]${reset} $*"; }
info()  { echo -e "${amarillo}[ .. ]${reset} $*"; }
fallo() { echo -e "${rojo}[FALLO]${reset} $*"; }

[[ $EUID -eq 0 ]] || { echo "Ejecutá como root."; exit 1; }

SCRIPT_URL="https://raw.githubusercontent.com/zuri360/netflix-proxy/refs/heads/main/tunel.sh"
LOCAL_SCRIPT=/root/tunel.sh
CMD=/usr/local/bin/dns
CRON_FILE=/etc/cron.d/tunel-dns
PAUSA=/etc/tunel-dns.pausado          # existe si la vigilancia quitó las reglas
LOG=/var/log/tunel-dns.log

# Guarda una copia local y crea el comando "dns", así se puede usar
# aunque el DNS del VPS esté roto y no se pueda descargar de GitHub.
autoinstalar() {
    local origen
    origen=$(readlink -f "$0" 2>/dev/null)
    if [[ "$origen" != "$LOCAL_SCRIPT" ]]; then
        if [[ -f "$origen" ]]; then
            cp "$origen" "$LOCAL_SCRIPT"                       # ejecutado desde un archivo
        else
            curl -fsSL --max-time 15 "$SCRIPT_URL" -o "${LOCAL_SCRIPT}.tmp" \
                && head -1 "${LOCAL_SCRIPT}.tmp" | grep -q '^#!/usr/bin/env bash' \
                && mv "${LOCAL_SCRIPT}.tmp" "$LOCAL_SCRIPT"    # ejecutado con bash <(curl ...)
            rm -f "${LOCAL_SCRIPT}.tmp"
        fi
        chmod +x "$LOCAL_SCRIPT" 2>/dev/null
    fi
    if [[ -f "$LOCAL_SCRIPT" && ! -x "$CMD" ]]; then
        printf '#!/usr/bin/env bash\nexec bash %s "$@"\n' "$LOCAL_SCRIPT" > "$CMD"
        chmod +x "$CMD"
    fi
}
autoinstalar

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Se excluye 127.0.0.0/8: si no, también se desvía el resolver local (127.0.0.53)
# y el propio VPS se queda sin poder resolver nombres.
regla() { echo "! -d 127.0.0.0/8 -p $1 --dport 53 -j DNAT --to-destination ${PROXY_IP}:53"; }

# Borra TODAS las reglas DNAT de DNS, apunten al proxy que apunten
# (proxy viejo, proxy nuevo, con o sin exclusión de loopback). Devuelve cuántas borró.
limpiar_todas() {
    local n=0 r
    while read -r r; do
        [[ -z "$r" ]] && continue
        iptables -t nat ${r/-A OUTPUT/-D OUTPUT} 2>/dev/null && n=$((n+1))
    done < <(iptables -t nat -S OUTPUT | grep -- '--dport 53' | grep -- '-j DNAT')
    echo "$n"
}

pedir_proxy() {
    local nueva
    echo -e "${negrita}IP del servidor netflix-proxy${reset}"
    read -rp "IP del proxy [Enter = ${PROXY_IP}]: " nueva
    nueva=$(echo "${nueva:-$PROXY_IP}" | tr -d ' ')
    valid_ip "$nueva" || { fallo "IP no válida: $nueva"; return 1; }
    if [[ -n "$GUARDADA" && "$nueva" != "$GUARDADA" ]]; then
        info "Cambiando de proxy: ${GUARDADA} -> ${nueva}"
    fi
    PROXY_IP="$nueva"
    echo "PROXY_IP=${PROXY_IP}" > "$CONF"
    GUARDADA="$PROXY_IP"
    ok "Proxy: ${PROXY_IP} (guardado en ${CONF})"
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

ip_local() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

msg_no_autorizado() {
    echo
    echo -e "${amarillo}${negrita}PROBABLEMENTE TU IP NO ESTA AUTORIZADA CONTACTA AL ADMINISTRADOR${reset}"
    echo -e "${amarillo}IP de este VPS: $(ip_local)${reset}"
    echo
}

# Si la IP no está autorizada, el proxy responde SU propia IP para cualquier dominio
# (incluso los que no están en la lista). Se prueba con example.com.
no_autorizado() {
    local r
    r=$(dig +short +time=3 +tries=1 example.com @8.8.8.8 | tail -1)
    [[ "$r" == "$PROXY_IP" ]]
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

# ---------- Vigilancia automática (cron) ----------
log_v() { echo "$(date '+%F %T') $*" >> "$LOG"; }

reglas_activas() { iptables -t nat -S OUTPUT | grep -- '--dport 53' | grep -q -- '-j DNAT'; }

# Pregunta DIRECTO al proxy (sin pasar por las reglas): debe responder su IP
# para ifconfig.co y la IP real para example.com. Si no, está caído o no autorizado.
proxy_ok_directo() {
    local a b
    a=$(dig +short +time=3 +tries=2 "$TEST_DOMAIN" @"$PROXY_IP" 2>/dev/null | tail -1)
    b=$(dig +short +time=3 +tries=2 example.com @"$PROXY_IP" 2>/dev/null | tail -1)
    [[ "$a" == "$PROXY_IP" && -n "$b" && "$b" != "$PROXY_IP" && "$b" != *";;"* ]]
}
tcp_ok_directo() { dig +tcp +short +time=3 +tries=2 "$TEST_DOMAIN" @"$PROXY_IP" 2>/dev/null | grep -qx "$PROXY_IP"; }

vigilar() {
    [[ -f $CONF ]] || exit 0                       # nunca se configuró un proxy
    command -v dig >/dev/null || exit 0
    if reglas_activas; then
        if ! proxy_ok_directo; then
            limpiar_todas >/dev/null
            netfilter-persistent save >/dev/null 2>&1
            touch "$PAUSA"
            log_v "Proxy ${PROXY_IP} caído o IP no autorizada -> reglas quitadas (usuarios con internet normal)"
        fi
    elif [[ -f $PAUSA ]]; then
        if proxy_ok_directo; then
            iptables -t nat -A OUTPUT $(regla udp)
            tcp_ok_directo && iptables -t nat -A OUTPUT $(regla tcp)
            netfilter-persistent save >/dev/null 2>&1
            rm -f "$PAUSA"
            log_v "Proxy ${PROXY_IP} responde y autorizado -> reglas reactivadas"
        fi
    fi
}

vigilancia_on() { [[ -f $CRON_FILE ]]; }

vigilancia() {
    if vigilancia_on; then
        echo -e "Vigilancia automática: ${verde}ACTIVADA${reset} (revisa cada 2 minutos)"
        read -rp "¿Desactivarla? (s/n): " r
        if [[ "$r" =~ ^[sS]$ ]]; then
            rm -f "$CRON_FILE" "$PAUSA"
            ok "Vigilancia desactivada"
        fi
    else
        echo -e "Vigilancia automática: ${rojo}DESACTIVADA${reset}"
        echo "Si el proxy se cae o quitan la autorización, quita las reglas sola"
        echo "(los usuarios siguen con internet) y las vuelve a poner cuando se arregla."
        read -rp "¿Activarla? (s/n): " r
        if [[ "$r" =~ ^[sS]$ ]]; then
            [[ -f $LOCAL_SCRIPT ]] || { fallo "Falta $LOCAL_SCRIPT"; return; }
            if ! command -v cron >/dev/null; then
                apt-get -y -qq install cron >/dev/null 2>&1
            fi
            systemctl enable --now cron >/dev/null 2>&1
            echo "*/2 * * * * root bash $LOCAL_SCRIPT vigilar >/dev/null 2>&1" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            ok "Vigilancia activada (cada 2 minutos)"
        fi
    fi
    if [[ -f $LOG ]]; then
        echo; echo -e "${negrita}Últimos eventos:${reset}"
        tail -5 "$LOG"
    fi
}

activar() {
    # En el menú pregunta la IP; con "bash tunel.sh activar" usa la guardada
    if [[ "$1" != "auto" ]]; then
        pedir_proxy || return
    else
        valid_ip "$PROXY_IP" || { fallo "IP del proxy no válida: $PROXY_IP"; return; }
        echo "PROXY_IP=${PROXY_IP}" > "$CONF"
    fi

    rm -f "$PAUSA"
    # Borra las reglas anteriores (incluidas las que apuntan a otro proxy)
    local n; n=$(limpiar_todas)
    [[ $n -gt 0 ]] && info "Reglas anteriores quitadas: $n"

    dependencias || return
    for p in udp tcp; do
        iptables -t nat -A OUTPUT $(regla $p) && ok "Regla $p agregada -> ${PROXY_IP}"
    done

    info "Probando..."
    sleep 1

    # Primero se verifica la autorización: si no está autorizada, la prueba
    # UDP daría un falso [ OK ] (el proxy responde su IP para todo)
    if no_autorizado; then
        limpiar_todas >/dev/null
        fallo "El proxy responde su IP para cualquier dominio (ej: example.com)"
        msg_no_autorizado
        echo "Se quitaron las reglas para no dejar sin internet a los usuarios del túnel."
        echo "Cuando autoricen la IP, volvé a usar la opción 1."
        guardar
        return
    fi
    probar

    # Si TCP no responde, se quita para no dejar el VPS sin DNS por TCP
    if ! dig +tcp +short +time=3 +tries=1 "$TEST_DOMAIN" @8.8.8.8 | grep -qx "$PROXY_IP"; then
        while iptables -t nat -D OUTPUT $(regla tcp) 2>/dev/null; do :; done
        echo -e "${amarillo}Se quitó la regla TCP porque el proxy no responde por TCP.${reset}"
        msg_no_autorizado
        echo "En el proxy ejecutá: menu2 -> opción 1 -> $(ip_local)"
        echo "(o: iptables -I INPUT -s $(ip_local)/32 -p tcp --dport 53 -j ACCEPT)"
    fi

    # Si el VPS se quedó sin internet, se deshace todo para no dejarlo roto
    if ! probar_internet; then
        limpiar_todas >/dev/null
        echo -e "${amarillo}Se quitaron las reglas para no dejar el VPS sin internet. Revisá el proxy.${reset}"
    fi
    guardar
}

quitar() {
    rm -f "$PAUSA"     # quitado a propósito: la vigilancia no las reactiva
    local n; n=$(limpiar_todas)
    [[ $n -gt 0 ]] && ok "Reglas quitadas: $n" || info "No había reglas activas"
    command -v netfilter-persistent >/dev/null && guardar
    echo "El DNS de este VPS volvió a la normalidad."
}

estado() {
    echo -e "${negrita}Proxy guardado:${reset} ${GUARDADA:-ninguno} (en uso: $PROXY_IP)"
    vigilancia_on && echo -e "${negrita}Vigilancia:${reset} ${verde}activada${reset}" \
                  || echo -e "${negrita}Vigilancia:${reset} desactivada"
    [[ -f $PAUSA ]] && echo -e "${amarillo}Reglas pausadas por la vigilancia (proxy caído o IP no autorizada)${reset}"
    echo -e "${negrita}Reglas DNAT de DNS activas:${reset}"
    local reglas
    reglas=$(iptables -t nat -S OUTPUT | grep -- '--dport 53' | grep -- '-j DNAT')
    if [[ -n "$reglas" ]]; then
        echo "$reglas" | sed 's/^/  /'
    else
        echo "  (ninguna)"
    fi
    if command -v dig >/dev/null; then
        echo
        if [[ -n "$reglas" ]] && no_autorizado; then
            fallo "El proxy responde su IP para cualquier dominio"
            msg_no_autorizado
        else
            probar
        fi
    fi
    probar_internet
}

desinstalar() {
    echo -e "${negrita}Esto revierte todo lo que hizo tunel.sh en este VPS:${reset}"
    echo " - Quita todas las reglas DNAT de DNS (de cualquier proxy, UDP y TCP)"
    echo " - Guarda el firewall sin esas reglas"
    echo " - Borra la IP guardada (${CONF}) y la vigilancia automática"
    echo " - Opcional: desinstala iptables-persistent y dnsutils"
    echo " - Opcional: borra el comando dns y /root/tunel.sh"
    read -rp "¿Continuar? (s/n): " r
    [[ "$r" =~ ^[sS]$ ]] || { echo "Cancelado."; return; }

    local n; n=$(limpiar_todas)
    ok "Reglas DNAT quitadas: $n"
    command -v netfilter-persistent >/dev/null && guardar
    rm -f "$CONF" && GUARDADA="" && ok "IP guardada borrada"
    rm -f "$CRON_FILE" "$PAUSA" "$LOG" && ok "Vigilancia automática quitada"

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

    read -rp "¿Borrar también el comando dns y /root/tunel.sh? (s/n): " r4
    if [[ "$r4" =~ ^[sS]$ ]]; then
        rm -f "$CMD" "$LOCAL_SCRIPT" && ok "Comando dns y /root/tunel.sh borrados"
    fi

    probar_internet
    echo -e "${verde}Desinstalación completa. El DNS de este VPS volvió a la normalidad.${reset}"
    echo "Recordá quitar la IP de este VPS en el proxy: menu2 -> opción 3."
}

case "$1" in
    activar)     activar auto; exit ;;
    quitar)      quitar;  exit ;;
    estado)      estado;  exit ;;
    desinstalar) desinstalar; exit ;;
    vigilar)     vigilar; exit ;;
esac

while true; do
    clear
    echo -e "${negrita}====== TÚNEL -> NETFLIX-PROXY ======${reset}"
    echo " Proxy DNS: ${GUARDADA:-sin configurar (por defecto $PROXY_IP)}"
    echo " Comando:   dns   (copia local: $LOCAL_SCRIPT)"
    echo "------------------------------------"
    echo " 1) Activar (UDP + TCP) y guardar"
    echo " 2) Quitar reglas"
    echo " 3) Estado y prueba"
    echo " 4) Desinstalar"
    echo " 5) Vigilancia automática $(vigilancia_on && echo -e "[${verde}ON${reset}]" || echo "[OFF]")"
    echo " 0) Salir"
    echo "------------------------------------"
    read -rp "Opción: " op
    echo
    case $op in
        1) activar ;;
        2) quitar ;;
        3) estado ;;
        4) desinstalar ;;
        5) vigilancia ;;
        0) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
    echo; read -rp "Enter para volver al menú..." _
done
