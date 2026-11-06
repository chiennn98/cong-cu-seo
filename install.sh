#!/usr/bin/env bash
# =============================================================
#  CÔNG CỤ SEO — cài đặt lên VPS (Ubuntu/Debian)
#  Cách dùng:
#    sudo bash install.sh                         -> chạy bằng IP của VPS
#    sudo bash install.sh seo.bigtreeland.vn      -> chạy bằng tên miền + HTTPS
#    sudo bash install.sh seo.bigtreeland.vn ban@email.com
#    sudo bash install.sh 2558                    -> chạy bằng IP, cổng riêng 2558
#  Chạy lại lệnh này bất cứ lúc nào để cập nhật bản mới.
# =============================================================
set -euo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"
PORT=80
if [[ "$DOMAIN" =~ ^[0-9]+$ ]]; then PORT="$DOMAIN"; DOMAIN=""; EMAIL=""; fi
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "Cổng không hợp lệ: $PORT"; exit 1; }
APP=cong-cu-seo
WEBROOT=/var/www/$APP
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/chienn98/cong-cu-seo/main}"
HTPASS=/etc/nginx/.htpasswd-$APP
SITE=/etc/nginx/sites-available/$APP

say(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m[X] %s\033[0m\n' "$*"; exit 1; }
ask(){ local q="$1" d="${2:-}" a=""; if [ -r /dev/tty ]; then { read -r -p "$q" a </dev/tty; } 2>/dev/null || true; fi; echo "${a:-$d}"; }

[ "$(id -u)" -eq 0 ] || die "Hãy chạy bằng quyền root: sudo bash install.sh $*"
command -v apt-get >/dev/null || die "Bộ cài này dành cho Ubuntu/Debian (có apt-get)."

say "1/5 Cài nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx openssl curl >/dev/null
systemctl enable --now nginx >/dev/null 2>&1 || true

say "2/5 Chép file web vào $WEBROOT"
mkdir -p "$WEBROOT"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
if [ -f "$HERE/index.html" ]; then
  cp "$HERE/index.html" "$WEBROOT/index.html"
  echo "   Dùng index.html nằm cạnh install.sh"
else
  curl -fsSL "$RAW_BASE/index.html" -o "$WEBROOT/index.html.new" || die "Không tải được $RAW_BASE/index.html — kiểm tra repo GitHub có để Public và có file index.html."
  mv "$WEBROOT/index.html.new" "$WEBROOT/index.html"
  echo "   Đã tải index.html từ GitHub"
fi
grep -q "CÔNG CỤ SEO" "$WEBROOT/index.html" || die "File index.html không phải CÔNG CỤ SEO."
chown -R www-data:www-data "$WEBROOT"; chmod 644 "$WEBROOT/index.html"

say "3/5 Mật khẩu đăng nhập"
if [ -f "$HTPASS" ]; then
  echo "   Đã có mật khẩu từ lần cài trước (xoá $HTPASS nếu muốn đặt lại)."
else
  USE_AUTH="$(ask '   Đặt mật khẩu để chỉ nhân viên vào được trang? [Y/n] ' Y)"
  if [[ "$USE_AUTH" =~ ^[Yy] ]]; then
    U="$(ask '   Tên đăng nhập [marketing]: ' marketing)"
    P="$(ask '   Mật khẩu (để trống = tạo ngẫu nhiên): ' '')"
    [ -n "$P" ] || P="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
    printf '%s:%s\n' "$U" "$(openssl passwd -apr1 "$P")" > "$HTPASS"
    chown root:www-data "$HTPASS"; chmod 640 "$HTPASS"
    echo "   Tên đăng nhập: $U"
    echo "   Mật khẩu:      $P   <-- HÃY LƯU LẠI"
  fi
fi
AUTH_CONF=""
[ -f "$HTPASS" ] && AUTH_CONF="auth_basic \"CONG CU SEO\"; auth_basic_user_file $HTPASS;"

say "4/5 Cấu hình nginx (cổng $PORT)"
if command -v ss >/dev/null; then
  USED_BY="$(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -v nginx | head -1 || true)"
  [ -z "$USED_BY" ] || die "Cổng $PORT đang bị chương trình khác dùng: $USED_BY — chọn cổng khác."
fi
SERVER_NAME="${DOMAIN:-_}"
LISTEN6=""; [ -s /proc/net/if_inet6 ] && LISTEN6="listen [::]:$PORT;"
cat > "$SITE" <<NGINX
server {
    listen $PORT;
    $LISTEN6
    server_name $SERVER_NAME;

    root $WEBROOT;
    index index.html;
    charset utf-8;
    client_max_body_size 1m;

    $AUTH_CONF

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    gzip on;
    gzip_types text/css application/javascript application/json;

    location = /index.html { expires -1; }
    location / { try_files \$uri /index.html; }
    location ~ /\. { deny all; }
}
NGINX
ln -sf "$SITE" /etc/nginx/sites-enabled/$APP
if [ "$PORT" = 80 ] && { [ -z "$DOMAIN" ] || [ ! -s /proc/net/if_inet6 ]; }; then
  rm -f /etc/nginx/sites-enabled/default   # để trang chạy được bằng IP / tránh lỗi IPv6
fi
nginx -t >/dev/null 2>&1 || { nginx -t; die "Cấu hình nginx lỗi."; }
if systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx; else systemctl restart nginx 2>/dev/null || nginx -s reload 2>/dev/null || nginx; fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 'Nginx Full' >/dev/null || true
  [ "$PORT" = 80 ] || ufw allow "$PORT/tcp" >/dev/null || true
fi

say "5/5 HTTPS"
if [ -n "$DOMAIN" ]; then
  IP_NOW="$(curl -fsS4 https://api.ipify.org 2>/dev/null || true)"
  IP_DNS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -n "$IP_NOW" ] && [ "$IP_NOW" != "$IP_DNS" ]; then
    warn "Tên miền $DOMAIN đang trỏ tới '${IP_DNS:-chưa có}', còn VPS có IP $IP_NOW."
    warn "Hãy tạo bản ghi A: $DOMAIN -> $IP_NOW (nếu dùng Cloudflare: tắt đám mây cam khi cài), đợi vài phút rồi chạy lại lệnh."
  else
    apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
    if [ -n "$EMAIL" ]; then CB_MAIL=(-m "$EMAIL"); else CB_MAIL=(--register-unsafely-without-email); fi
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect "${CB_MAIL[@]}"; then
      echo "   Đã bật HTTPS, tự gia hạn."
    else
      warn "Chưa bật được HTTPS. Web vẫn chạy ở http://$DOMAIN — kiểm tra DNS rồi chạy lại."
    fi
  fi
else
  echo "   Bỏ qua (chưa có tên miền). Muốn có HTTPS: chạy lại với tên miền (dùng cổng 80/443)."
fi

IP="$(curl -fsS4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
say "XONG!"
if [ -n "$DOMAIN" ]; then echo "   Mở web:        https://$DOMAIN"; echo "   Trang quản trị: https://$DOMAIN/#cms";
else
  HOSTPORT="$IP"; [ "$PORT" = 80 ] || HOSTPORT="$IP:$PORT"
  echo "   Mở web:        http://$HOSTPORT"; echo "   Trang quản trị: http://$HOSTPORT/#cms"
  [ "$PORT" = 80 ] || echo "   Nhớ mở cổng $PORT (TCP) trong Firewall/Security Group của nhà cung cấp VPS."
fi
echo "   Cập nhật bản mới: chạy lại đúng lệnh cài."
