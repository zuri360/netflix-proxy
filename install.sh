#!/usr/bin/env bash
# =====================================================================
#  Instalador automático de netflix-proxy (github.com/ab77/netflix-proxy)
#  Probado para Ubuntu 22.04 / Debian. Requiere root y VPS KVM.
#
#  Instalación rápida:
#    bash <(curl -fsSL https://raw.githubusercontent.com/zuri360/netflix-proxy/refs/heads/main/install.sh)
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
MENU_URL=https://raw.githubusercontent.com/zuri360/netflix-proxy/refs/heads/main/menu2
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
if curl -fsSL "$MENU_URL" -o /tmp/menu2 && head -1 /tmp/menu2 | grep -q '^#!/usr/bin/env bash'; then
    mv /tmp/menu2 /usr/local/bin/menu2
    chmod +x /usr/local/bin/menu2
else
    rm -f /tmp/menu2
    echo -e "${amarillo}[AVISO]${reset} No se pudo descargar menu2 desde GitHub. Instalalo después con:"
    echo "  curl -fsSL $MENU_URL -o /usr/local/bin/menu2 && chmod +x /usr/local/bin/menu2"
fi
[[ -x /usr/local/bin/menu2 ]] && ok "Menú instalado: escribí menu2 para abrirlo"

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
