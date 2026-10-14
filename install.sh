#!/usr/bin/env bash
# =====================================================================
#  Instalador automático de netflix-proxy (github.com/ab77/netflix-proxy)
#  Probado para Ubuntu 22.04 / Debian. Requiere root y VPS KVM.
#
#  Uso:  bash install.sh                -> genera contraseña admin al azar
#        bash install.sh Clave26x    -> usa esa contraseña (6 a 8 letras o números)
#
#  Incluye los arreglos para versiones nuevas:
#   - libera el puerto 53 (systemd-resolved)
#   - IP pública fija (el servidor mgmt.unzoner.com ya no existe)
#   - PyYAML 5.4.1 con Cython < 3
#   - docker<7, requests<2.32, urllib3<2 para docker-compose 1.29
#   - dependencias del panel (passlib, web.py, dnspython)
#   - cuenta admin vencida (la base trae vencimiento 2026-01-01)
# =====================================================================

INSTALL_DIR=/root/netflix-proxy
REPO_URL=https://github.com/ab77/netflix-proxy/archive/latest.tar.gz
ADMIN_PASS="${1:-}"

verde='\e[32m'; rojo='\e[31m'; amarillo='\e[33m'; negrita='\e[1m'; reset='\e[0m'
ok()    { echo -e "${verde}[ OK ]${reset} $*"; }
info()  { echo -e "${amarillo}[ .. ]${reset} $*"; }
error() { echo -e "${rojo}[ERROR]${reset} $*"; exit 1; }

APT="apt-get"

# ---------- Comprobaciones ----------
[[ $EUID -eq 0 ]] || error "Ejecutá este script como root."
. /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || error "Solo funciona en Ubuntu o Debian (detectado: $ID)."

virt=$(systemd-detect-virt 2>/dev/null || echo "desconocido")
[[ "$virt" == "openvz" || "$virt" == "lxc" ]] && error "Virtualización '$virt' no soportada. Necesitás un VPS KVM."

if [[ -n "$ADMIN_PASS" && ! "$ADMIN_PASS" =~ ^[A-Za-z0-9]{6,8}$ ]]; then
    error "La contraseña debe tener entre 6 y 8 caracteres, solo letras y números (límite del panel)."
fi

echo -e "${negrita}ATENCIÓN:${reset} este instalador desactiva ufw, cambia reglas de iptables y libera el puerto 53."
echo "No lo uses en un VPS donde tengas otros paneles VPN funcionando."
read -rp "¿Continuar? (s/n): " resp
[[ "$resp" =~ ^[sS]$ ]] || error "Instalación cancelada."

# ---------- Paquetes ----------
info "Instalando paquetes del sistema..."
export DEBIAN_FRONTEND=noninteractive
# Evita choques con las actualizaciones automáticas de Ubuntu durante la instalación
systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99netflix-proxy-lock
trap 'rm -f /etc/apt/apt.conf.d/99netflix-proxy-lock; systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1' EXIT
$APT update -qq
$APT -y -qq install curl sudo vim dnsutils net-tools git sqlite3 \
    python3 python3-pip python3-venv python3-dev build-essential \
    libffi-dev libssl-dev >/dev/null || error "Falló la instalación de paquetes."
ok "Paquetes instalados"

# ---------- IP pública ----------
info "Detectando IP pública..."
IP=$(curl -4 -s --max-time 10 https://api.ipify.org)
[[ -z "$IP" ]] && IP=$(curl -4 -s --max-time 10 https://ifconfig.me)
[[ -z "$IP" ]] && IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "No se pudo detectar la IP pública."
ok "IP pública: $IP"

# ---------- Docker ----------
if ! command -v docker >/dev/null 2>&1; then
    info "Instalando Docker (log en /root/docker-install.log)..."
        if ! curl -fsSL https://get.docker.com | sh >/root/docker-install.log 2>&1; then
        info "Falló el instalador oficial, probando con docker.io de Ubuntu..."
                $APT -y -qq install docker.io >>/root/docker-install.log 2>&1
    fi
fi
systemctl enable --now docker >/dev/null 2>&1
command -v docker >/dev/null 2>&1 || error "No se pudo instalar Docker."
ok "Docker listo"

# ---------- Puerto 53 ----------
info "Liberando el puerto 53..."
if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNSStubListener=no\n" > /etc/systemd/resolved.conf.d/netflix-proxy.conf
    systemctl restart systemd-resolved
fi
rm -f /etc/resolv.conf
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
sleep 2
if ss -lunp | grep -q ':53 ' && ! ss -lunp | grep ':53 ' | grep -q docker; then
    ss -lunp | grep ':53 '
    error "Otro programa sigue usando el puerto 53. Detenelo y volvé a ejecutar."
fi
ok "Puerto 53 libre"

# ---------- Descarga ----------
if [[ -d "$INSTALL_DIR" ]]; then
    backup="${INSTALL_DIR}.bak.$(date +%s)"
    info "Ya existe $INSTALL_DIR, se mueve a $backup"
    mv "$INSTALL_DIR" "$backup"
fi
info "Descargando netflix-proxy..."
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR" || error "No se pudo crear $INSTALL_DIR"
curl -fsSL "$REPO_URL" | tar xz --strip-components=1 || error "Falló la descarga."
ok "Descargado en $INSTALL_DIR"

# ---------- Parche de IP en build.sh ----------
sed -i "s|^EXTIP=\$(get_ext_ipaddr 4)|EXTIP=${IP}|" build.sh
grep -q "^EXTIP=${IP}$" build.sh || error "No se pudo parchear build.sh (cambió el script original)."
ok "build.sh parcheado con IP fija"

# ---------- Entorno Python ----------
fix_python() {
    . "$INSTALL_DIR/venv/bin/activate"
    pip install -q --upgrade pip wheel
    pip install -q "cython<3.0.0"
    pip install -q "pyyaml==5.4.1" --no-build-isolation
    pip install -q -r "$INSTALL_DIR/requirements.txt"
    pip install -q -r "$INSTALL_DIR/auth/requirements.txt"
    pip install -q "docker<7" "requests<2.32" "urllib3<2"
    deactivate
}
info "Preparando Python (puede tardar unos minutos)..."
python3 -m venv "$INSTALL_DIR/venv" || error "No se pudo crear el venv."
fix_python || error "Falló la instalación de librerías Python."
"$INSTALL_DIR/venv/bin/python" -c "import passlib, web, dns, yaml" 2>/dev/null \
    || error "Faltan librerías Python después de instalarlas."
ok "Python listo"

# ---------- build.sh ----------
containers_ok() {
    docker ps --format '{{.Names}}' | grep -q sniproxy && \
    docker ps --format '{{.Names}}' | grep -q dnsmasq
}
info "Ejecutando build.sh original..."
./build.sh
if ! containers_ok; then
    info "Los contenedores no levantaron, se reaplican arreglos y se reintenta..."
    fix_python
    ./build.sh
fi
containers_ok || error "Los contenedores no arrancaron. Revisá $INSTALL_DIR/netflix-proxy.log"
ok "Contenedores funcionando"

# ---------- Cuenta admin ----------
info "Configurando cuenta admin..."
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
cd "$INSTALL_DIR/auth" || error "No existe la carpeta auth."
HASH=$("$INSTALL_DIR/venv/bin/python" pbkdf2_sha256_hash.py "$ADMIN_PASS" | awk '{print $2}')
[[ "$HASH" == \$pbkdf2-sha256\$* ]] || error "No se pudo generar el hash de la contraseña."
sqlite3 db/auth.db "UPDATE users SET password='${HASH}', expires='2099-12-31' WHERE username='admin';" \
    || error "No se pudo actualizar la base de datos."
systemctl restart netflix-proxy-admin
ok "Admin configurado (vence 2099-12-31)"

# ---------- Menú (menu2) ----------
info "Instalando menú de gestión (comando: menu2)..."
cat > /etc/netflix-proxy-menu.conf <<CONFEOF
IP=${IP}
ADMIN_PASS=${ADMIN_PASS}
CONFEOF
chmod 600 /etc/netflix-proxy-menu.conf
cat > /usr/local/bin/menu2 <<'MENUEOF'
#!/usr/bin/env bash
# Menú de gestión de netflix-proxy — se abre escribiendo: menu2

CONF=/etc/netflix-proxy-menu.conf
DIR=/root/netflix-proxy
DB=$DIR/auth/db/auth.db

verde='\e[32m'; rojo='\e[31m'; amarillo='\e[33m'; negrita='\e[1m'; reset='\e[0m'

[[ $EUID -eq 0 ]] || { echo "Ejecutá menu2 como root."; exit 1; }
[[ -f $CONF ]] || { echo "Falta $CONF. Reinstalá con install.sh."; exit 1; }
. "$CONF"   # define IP y ADMIN_PASS

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
pausa()    { echo; read -rp "Enter para volver al menú..." _; }

agregar_ip() {
    read -rp "IP a autorizar: " nueva
    nueva=$(echo "$nueva" | tr -d ' ')
    valid_ip "$nueva" || { echo -e "${rojo}IP no válida.${reset}"; return; }
    curl -s -o /dev/null "http://${IP}:8080/autoadd?ip=${nueva}&username=admin&password=${ADMIN_PASS}"
    # El panel a veces no aplica la regla en el firewall: se asegura acá
    if ! iptables -t nat -C PREROUTING -s "${nueva}/32" -i eth0 -j ACCEPT 2>/dev/null; then
        iptables -t nat -I PREROUTING -s "${nueva}/32" -i eth0 -j ACCEPT
    fi
    netfilter-persistent save >/dev/null 2>&1
    if sqlite3 "$DB" "SELECT 1 FROM IPADDRS WHERE ipaddr='${nueva}' LIMIT 1;" | grep -q 1; then
        echo -e "${verde}IP ${nueva} autorizada (panel + firewall).${reset}"
    else
        echo -e "${amarillo}Firewall OK, pero el panel no la registró. Revisá la contraseña en ${CONF}.${reset}"
    fi
}

ver_ips() {
    echo -e "${negrita}IPs autorizadas:${reset}"
    sqlite3 -header -column "$DB" "SELECT ID, created, ipaddr FROM IPADDRS ORDER BY ID;"
}

eliminar_ip() {
    ver_ips; echo
    read -rp "IP a eliminar: " ip_del
    ip_del=$(echo "$ip_del" | tr -d ' ')
    valid_ip "$ip_del" || { echo -e "${rojo}IP no válida.${reset}"; return; }
    sqlite3 "$DB" "DELETE FROM IPADDRS WHERE ipaddr='${ip_del}';"
    while iptables -t nat -D PREROUTING -s "${ip_del}/32" -i eth0 -j ACCEPT 2>/dev/null; do :; done
    netfilter-persistent save >/dev/null 2>&1
    echo -e "${verde}IP ${ip_del} eliminada (panel + firewall).${reset}"
}

limpiar_duplicados() {
    sqlite3 "$DB" "DELETE FROM IPADDRS WHERE ID NOT IN (SELECT MIN(ID) FROM IPADDRS GROUP BY ipaddr);"
    echo -e "${verde}Duplicados eliminados.${reset}"; ver_ips
}

agregar_dominio() {
    read -rp "Dominio a pasar por el proxy (ej: ejemplo.com): " dom
    dom=$(echo "$dom" | tr -d ' ' | tr 'A-Z' 'a-z')
    [[ "$dom" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo -e "${rojo}Dominio no válido.${reset}"; return; }
    grep -q "^address=/${dom}/" "$DIR/dnsmasq.conf" || echo "address=/${dom}/${IP}" >> "$DIR/dnsmasq.conf"
    grep -qx "$dom" "$DIR/proxy-domains.txt" || echo "$dom" >> "$DIR/proxy-domains.txt"
    echo "+ docker restart dnsmasq"; docker restart dnsmasq
    sleep 2
    echo "+ dig +short ${dom} @${IP}"; dig +short "$dom" @"$IP"
    if [[ "$(dig +short "$dom" @"$IP" | head -1)" == "$IP" ]]; then
        echo -e "${verde}${dom} ahora pasa por el proxy.${reset}"
    else
        echo -e "${amarillo}Se agregó, pero dig no responde ${IP}. Revisá dnsmasq.conf.${reset}"
    fi
}

comprobar_dominio() {
    read -rp "Dominio a comprobar (ej: speedtest.net): " dom
    dom=$(echo "$dom" | tr -d ' ')
    [[ -n "$dom" ]] || return
    echo "+ dig +short ${dom} @${IP}"
    res=$(dig +short "$dom" @"$IP")
    echo "$res"
    if echo "$res" | grep -qx "$IP"; then
        echo -e "${verde}${dom} pasa por el proxy.${reset}"
    else
        echo -e "${amarillo}${dom} NO pasa por el proxy (responde su IP real).${reset}"
    fi
}

reiniciar_dnsmasq() {
    echo "+ docker restart dnsmasq"; docker restart dnsmasq
    echo -e "${verde}dnsmasq reiniciado.${reset}"
}

ver_dominios() {
    echo -e "${negrita}Dominios que pasan por el proxy:${reset}"
    grep -o '^address=/[^/]*/' "$DIR/dnsmasq.conf" | cut -d/ -f2 | sort -u | (column 2>/dev/null || cat)
}

cambiar_pass() {
    read -rp "Nueva contraseña admin (6 a 8 letras o números): " np
    [[ "$np" =~ ^[A-Za-z0-9]{6,8}$ ]] || { echo -e "${rojo}Contraseña no válida.${reset}"; return; }
    hash=$(cd "$DIR/auth" && "$DIR/venv/bin/python" pbkdf2_sha256_hash.py "$np" | awk '{print $2}')
    [[ "$hash" == \$pbkdf2-sha256\$* ]] || { echo -e "${rojo}No se pudo generar el hash.${reset}"; return; }
    sqlite3 "$DB" "UPDATE users SET password='${hash}', expires='2099-12-31' WHERE username='admin';"
    sed -i "s/^ADMIN_PASS=.*/ADMIN_PASS=${np}/" "$CONF"
    ADMIN_PASS=$np
    systemctl restart netflix-proxy-admin
    echo -e "${verde}Contraseña cambiada a: ${np}${reset}"
}

estado() {
    echo -e "${negrita}Contenedores:${reset}"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|dnsmasq|sniproxy|caddy'
    echo
    systemctl is-active --quiet netflix-proxy-admin \
        && echo -e " ${verde}●${reset} panel admin activo" || echo -e " ${rojo}●${reset} panel admin detenido"
}

reiniciar() {
    docker restart $(docker ps -a --format '{{.Names}}' | grep -E 'dnsmasq|sniproxy|caddy') >/dev/null 2>&1
    systemctl restart netflix-proxy-admin
    echo -e "${verde}Servicios reiniciados.${reset}"; echo; estado
}

while true; do
    clear
    echo -e "${negrita}========= NETFLIX-PROXY =========${reset}"
    echo -e " Panel: http://${IP}:8080/   DNS: ${IP}"
    echo -e " Admin: admin / ${ADMIN_PASS}"
    echo "---------------------------------"
    echo " 1) Agregar IP"
    echo " 2) Ver IPs autorizadas"
    echo " 3) Eliminar IP"
    echo " 4) Limpiar IPs duplicadas"
    echo " 5) Agregar dominio al proxy"
    echo " 6) Comprobar dominio (dig)"
    echo " 7) Ver dominios del proxy"
    echo " 8) Reiniciar dnsmasq"
    echo " 9) Cambiar contraseña admin"
    echo "10) Estado de servicios"
    echo "11) Reiniciar todos los servicios"
    echo " 0) Salir"
    echo "---------------------------------"
    read -rp "Opción: " op
    echo
    case $op in
        1) agregar_ip ;;
        2) ver_ips ;;
        3) eliminar_ip ;;
        4) limpiar_duplicados ;;
        5) agregar_dominio ;;
        6) comprobar_dominio ;;
        7) ver_dominios ;;
        8) reiniciar_dnsmasq ;;
        9) cambiar_pass ;;
        10) estado ;;
        11) reiniciar ;;
        0) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
    pausa
done
MENUEOF
chmod +x /usr/local/bin/menu2
ok "Menú instalado: escribí menu2 para abrirlo"

# ---------- Prueba final ----------
sleep 2
RESP=$(dig +short netflix.com @"$IP" | head -1)
if [[ "$RESP" == "$IP" ]]; then
    ok "DNS responde correctamente"
else
    echo -e "${amarillo}[AVISO]${reset} netflix.com respondió '$RESP' en vez de '$IP'. Revisá el log."
fi

echo
echo -e "${verde}${negrita}=========== INSTALACIÓN COMPLETA ===========${reset}"
echo -e " Panel:       ${negrita}http://${IP}:8080/${reset}"
echo -e " Usuario:     ${negrita}admin${reset}"
echo -e " Contraseña:  ${negrita}${ADMIN_PASS}${reset}"
echo -e " DNS a usar:  ${negrita}${IP}${reset} (sin DNS secundario)"
echo -e "${verde}${negrita}============================================${reset}"
echo -e " Menú:        ${negrita}menu2${reset} (agregar/ver/eliminar IPs, dominios, contraseña)"
echo " - Autorizá la IP de cada cliente desde el panel (botón Add) o con menu2."
echo " - Desactivá IPv6 y el 'DNS seguro' del navegador en los dispositivos."
echo " - Netflix suele bloquear IPs de datacenter aunque todo esté bien instalado."
