# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    printf "${GREEN}[INFO]${NC} $1\n"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} $1\n"
}

log_error() {
    printf "${RED}[ERROR]${NC} $1\n"
}


# is service exists
is_service_exists() {
    local x=$1
    if systemctl status "${x}" 2> /dev/null | grep -Fq "Active:"; then
        return 0
    else
        return 1
    fi
}

if is_service_exists 'haproxy'; then
    log_info "Service haproxy already installed"
    exit 0
fi

# Prerequisites check
check_dep() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required tool '$1' is not installed."
        exit 1
    fi
}

log_info "Checking build prerequisites..."
check_dep "git"
check_dep "make"
check_dep "gcc" || check_dep "clang"

### read args
GIT_REPO=https://github.com/haproxy/haproxy.git
GIT_BRANCH=v2.6-dev12
GIT_DIR=haproxy
USE_SYSTEMD=1
TARGET=generic
CPU=generic
ARCH=
declare -a other_make_args

for arg in "$@"; do
    [[ -z $arg ]] && continue
    if [[ "$arg" =~ .*haproxy.* ]]; then
    # Пример, https://github.com/haproxy/haproxy.git-v2.6-dev12
        repo="${arg%%-*}" # значение до знака -
        branch="${arg#*-}"  # значение после знака -
        if [[ -z $repo ]]; then
            GIT_REPO=$repo
        fi
        if [[ -z $branch ]]; then
            GIT_BRANCH=$branch
        fi

    elif [[ "$arg" =~ ^TARGET=.+$ ]]; then
    # беру любой символ, не красиво, но make ругнется сам на то, что не поддерживает
        value="${arg#*=}"
        TARGET=$value
    elif [[ "$arg" =~ ^ARCH=.+$ ]]; then
    # беру любой символ, не красиво, но make ругнется сам на то, что не поддерживает
        value="${arg#*=}"
        ARCH=$value
    elif [[ "$arg" =~ ^CPU=.+$ ]]; then
    # беру любой символ, не красиво, но make ругнется сам на то, что не поддерживает
        value="${arg#*=}"
        CPU=$value
    elif [[ "$arg" =~ ^USE_SYSTEMD=.+$ ]]; then
        value="${arg#*=}"
        USE_SYSTEMD=$value
    else
    # остальные параметры добавляю как есть
        other_make_args+=( $arg )
    fi
done

### Clone repo
log_info "Clone repository $GIT_REPO and branch=$GIT_BRANCH..."
git clone $GIT_REPO -b $GIT_BRANCH $GIT_DIR

cd $GIT_DIR
# echo "TARGET=$TARGET CPU=$CPU ARCH=$ARCH" "${other_make_args[@]}"
log_info "building haproxy..."
LANG=C make -j $(nproc) TARGET=$TARGET CPU=$CPU ARCH=$ARCH USE_SYSTEMD=$USE_SYSTEMD "${other_make_args[@]}"

log_info "install builded service..."

### Generate Service file
cat > haproxy.service<< EOF
[Unit]
Description=HAProxy Load Balancer
After=network-online.target rsyslog.service syslog-ng.service
Wants=network-online.target

[Service]
EnvironmentFile=-/etc/default/haproxy
EnvironmentFile=-/etc/sysconfig/haproxy
ExecStartPre=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -c -q  -S /run/haproxy-master.sock
ExecStart=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -S /run/haproxy-master.sock
ExecReload=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -c -q -S /run/haproxy-master.sock
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
Restart=always
SuccessExitStatus=143
Type=notify

[Install]
WantedBy=multi-user.target
EOF


cat > haproxy.cfg << EOF
global
    daemon
    maxconn 256

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

listen http-in
    bind *:80
    server server1 127.0.0.1:8080 maxconn 32
EOF


mv haproxy /usr/sbin/haproxy
mv haproxy.cfg /etc/haproxy/haproxy.cfg
mv haproxy.service /lib/systemd/system/haproxy.service


log_info "reload list of services..."
# обновляем список сервисов
# daemon-reload                       Reload systemd manager configuration
systemctl daemon-reload
