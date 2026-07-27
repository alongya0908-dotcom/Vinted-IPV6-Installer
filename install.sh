#!/usr/bin/env bash
set -euo pipefail

# Interactive fleet installer. This outer layer downloads one fixed runtime
# release, verifies it before mutation, then delegates to the transactional
# install_admin_console.sh contained in that release.

DEFAULT_VERSION="v1.8.11"
DEFAULT_DISTRIBUTION_REPOSITORY="alongya0908-dotcom/Vinted-IPV6-Installer"
DEFAULT_ARCHIVE_SHA256="5feb933d5e1ee2e3045dace84cd6524734161e40792061a57c6b4bb3ed807991"
DOWNLOAD_WORK_DIR=""
RELEASE_STAGE_DIR=""
PROMPT_FD=""
VERIFIED_MANIFEST_COMMIT=""
VERIFIED_BINARY_SHA=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

contains_line_break() {
  [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]
}

validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_archive_sha256_pin() {
  [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]
}

validate_repository() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

validate_ipv4() {
  local value="$1" octet
  local -a octets
  IFS='.' read -r -a octets <<<"$value"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

validate_boolean() {
  [[ "$1" == "0" || "$1" == "1" ]]
}

validate_public_domain() {
  local value="${1,,}" label
  local -a labels
  [[ -n "$value" && ${#value} -le 253 ]] || return 1
  contains_line_break "$value" && return 1
  [[ "$value" != *".."* && "$value" != .* && "$value" != *. ]] || return 1
  IFS='.' read -r -a labels <<<"$value"
  (( ${#labels[@]} >= 2 )) || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

derive_sslip_domain() {
  validate_ipv4 "$1" || return 1
  printf '%s.sslip.io\n' "${1//./-}"
}

write_trusted_https_nginx_config() {
  local domain="$1" management_port="$2" destination="$3"
  validate_public_domain "$domain" || return 1
  validate_port "$management_port" || return 1
  cat >"$destination" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    client_max_body_size 10m;

    location / {
        proxy_pass https://127.0.0.1:$management_port;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}
EOF
}

configure_trusted_https() {
  local public_ipv4="$1" domain="$2" management_port="$3"
  local backup_dir config_path config_temp package_attempt resolved
  local packages_ready=0 previous_config=0

  validate_ipv4 "$public_ipv4" || return 1
  validate_public_domain "$domain" || return 1
  validate_port "$management_port" || return 1
  command -v apt-get >/dev/null 2>&1 || {
    echo "Trusted HTTPS requires apt-get on the supported Ubuntu host." >&2
    return 1
  }
  command -v getent >/dev/null 2>&1 || {
    echo "Trusted HTTPS requires getent for the preflight DNS check." >&2
    return 1
  }

  resolved="$(
    getent ahostsv4 "$domain" 2>/dev/null |
      awk '$2 == "STREAM" { print $1 }' |
      sort -u
  )"
  grep -Fqx "$public_ipv4" <<<"$resolved" || {
    echo "Trusted HTTPS skipped: $domain does not resolve to $public_ipv4." >&2
    return 1
  }

  if command -v nginx >/dev/null 2>&1 &&
     command -v certbot >/dev/null 2>&1 &&
     dpkg-query -W -f='${Status}\n' python3-certbot-nginx 2>/dev/null |
       grep -Fqx 'install ok installed'; then
    packages_ready=1
  else
    export DEBIAN_FRONTEND=noninteractive
    for package_attempt in 1 2 3 4 5; do
      if apt-get update &&
         apt-get install -y nginx certbot python3-certbot-nginx; then
        packages_ready=1
        break
      fi
      echo "Package manager is busy; retrying trusted HTTPS setup ($package_attempt/5)." >&2
      sleep 3
    done
  fi
  (( packages_ready == 1 )) || return 1
  for required_command in certbot nginx; do
    command -v "$required_command" >/dev/null 2>&1 || return 1
  done

  if command -v ufw >/dev/null 2>&1 &&
     ufw status 2>/dev/null | grep -Fq 'Status: active'; then
    ufw allow 80/tcp >/dev/null || return 1
    ufw allow 443/tcp >/dev/null || return 1
  fi

  backup_dir="/var/backups/vinted-ipv6/tls-proxy-$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "$backup_dir" || return 1
  config_path="/etc/nginx/sites-available/vinted-ipv6-tls"
  if [[ -e "$config_path" || -L "$config_path" ]]; then
    cp -a "$config_path" "$backup_dir/" || return 1
    previous_config=1
  fi
  config_temp="$(mktemp /tmp/vinted-ipv6-nginx.XXXXXXXX)"
  if ! write_trusted_https_nginx_config \
      "$domain" "$management_port" "$config_temp"; then
    rm -f -- "$config_temp"
    return 1
  fi
  install -m 0644 "$config_temp" "$config_path" || {
    rm -f -- "$config_temp"
    return 1
  }
  rm -f -- "$config_temp"
  ln -sfn "$config_path" /etc/nginx/sites-enabled/vinted-ipv6-tls ||
    return 1
  if ! nginx -t || ! systemctl enable --now nginx; then
    if (( previous_config == 1 )); then
      cp -a "$backup_dir/vinted-ipv6-tls" "$config_path"
    else
      rm -f -- /etc/nginx/sites-enabled/vinted-ipv6-tls "$config_path"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    return 1
  fi

  if ! certbot --nginx -d "$domain" \
      --non-interactive --agree-tos --register-unsafely-without-email \
      --redirect --keep-until-expiring ||
     ! nginx -t ||
     ! systemctl reload nginx ||
     ! curl --fail --silent --show-error --max-time 20 \
       "https://$domain/healthz" >/dev/null; then
    if (( previous_config == 1 )); then
      cp -a "$backup_dir/vinted-ipv6-tls" "$config_path"
    else
      rm -f -- /etc/nginx/sites-enabled/vinted-ipv6-tls "$config_path"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    return 1
  fi
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  /usr/local/bin/vinted-ipv6 \
    -data-dir /var/lib/vinted-ipv6 \
    -set-public-host "$domain" >/dev/null || return 1
  printf '%s\n' "$backup_dir" >/var/lib/vinted-ipv6/tls-proxy-last-backup
  chmod 0600 /var/lib/vinted-ipv6/tls-proxy-last-backup
}

normalize_prefix() {
  local value="${1,,}"
  value="${value//[[:space:]]/}"
  value="${value%/48}"
  value="${value%::}"
  if [[ "$value" =~ ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

normalize_prefix_list() {
  local raw="$1" item normalized result=""
  local -a items
  IFS=',' read -r -a items <<<"$raw"
  (( ${#items[@]} > 0 )) || return 1
  for item in "${items[@]}"; do
    normalized="$(normalize_prefix "$item")" || return 1
    if [[ ",$result," != *",$normalized,"* ]]; then
      result="${result:+$result,}$normalized"
    fi
  done
  [[ -n "$result" ]] || return 1
  printf '%s\n' "$result"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_proxy_port_range() {
  validate_port "$1" && validate_port "$2" &&
    (( 10#$1 >= 1000 && 10#$1 <= 10#$2 ))
}

validate_subnet_start() {
  local value="${1,,}"
  value="${value#0x}"
  [[ "$value" =~ ^[0-9a-f]{1,4}$ ]] &&
    (( 16#$value >= 1 && 16#$value <= 65535 ))
}

validate_admin_path() {
  local lower="${1,,}"
  [[ "$1" =~ ^/[A-Za-z0-9_-]{1,128}$ ]] &&
    [[ "$lower" != "/api" && "$lower" != "/healthz" ]]
}

validate_reserved_ports() {
  local value="$1" port
  local -a ports
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  IFS=',' read -r -a ports <<<"$value"
  for port in "${ports[@]}"; do
    validate_port "$port" || return 1
  done
}

remove_reserved_port() {
  local value="$1" excluded="$2" port result=""
  local -a ports
  [[ -n "$value" ]] || return 0
  IFS=',' read -r -a ports <<<"$value"
  for port in "${ports[@]}"; do
    [[ "$port" == "$excluded" ]] && continue
    [[ ",$result," == *",$port,"* ]] && continue
    result="${result:+$result,}$port"
  done
  printf '%s\n' "$result"
}

version_is_older() {
  local candidate="${1#v}" installed="${2#v}" index
  local -a candidate_parts installed_parts
  IFS='.' read -r -a candidate_parts <<<"$candidate"
  IFS='.' read -r -a installed_parts <<<"$installed"
  for index in 0 1 2; do
    if (( 10#${candidate_parts[$index]} < 10#${installed_parts[$index]} )); then
      return 0
    fi
    if (( 10#${candidate_parts[$index]} > 10#${installed_parts[$index]} )); then
      return 1
    fi
  done
  return 1
}

validate_archive_entries() {
  local archive="$1" root_name="$2" entry relative listing type
  local names="" details=""
  local -A seen_entries=()

  names="$(tar -tzf "$archive")" || return 1
  details="$(tar -tvzf "$archive")" || return 1

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || return 1
    [[ -z "${seen_entries["$entry"]+present}" ]] || return 1
    seen_entries["$entry"]=1
    case "$entry" in
      /*|../*|*/../*|*/..|*//*)
        return 1
        ;;
    esac
    [[ "$entry" == "$root_name" || "$entry" == "$root_name/"* ]] ||
      return 1
    relative="${entry#"$root_name"}"
    relative="${relative#/}"
    relative="${relative%/}"
    case "$relative" in
      ""|\
      bin|bin/vinted-ipv6-linux-amd64|\
      web|web/index.html|web/app.js|web/styles.css|\
      web/customer|web/customer/index.html|web/customer/client.js|web/customer/client.css|web/customer/login.js|\
      web/customer/portal|web/customer/portal/index.html|\
      deployment|\
      deployment/install_admin_console.sh|\
      deployment/rollback_admin_console.sh|\
      deployment/systemd_env.sh|\
      deployment/vinted-ipv6.service|\
      deployment/verify_ipv6_prefix.sh|\
      release-files.sha256|\
      release-manifest.txt)
        ;;
      *)
        return 1
        ;;
    esac
  done <<<"$names"

  while IFS= read -r listing; do
    type="${listing:0:1}"
    [[ "$type" == "d" || "$type" == "-" ]] || return 1
  done <<<"$details"
}

verify_payload() {
  local payload_root="$1" expected_version="$2"
  local required_path key value version_count=0 commit_count=0
  local binary_count=0 files_count=0 epoch_count=0 manifest_version=""
  local manifest_commit="" manifest_binary_sha="" manifest_files_sha=""
  local manifest_epoch="" binary_sha files_sha version_output
  local file_hash file_path file_index=0
  local -a expected_files=(
    bin/vinted-ipv6-linux-amd64
    deployment/install_admin_console.sh
    deployment/rollback_admin_console.sh
    deployment/systemd_env.sh
    deployment/verify_ipv6_prefix.sh
    deployment/vinted-ipv6.service
    web/app.js
    web/customer/client.css
    web/customer/client.js
    web/customer/index.html
    web/customer/login.js
    web/customer/portal/index.html
    web/index.html
    web/styles.css
  )

  for required_path in \
    bin/vinted-ipv6-linux-amd64 \
    web/index.html \
    web/app.js \
    web/styles.css \
    web/customer/index.html \
    web/customer/client.js \
    web/customer/client.css \
    web/customer/login.js \
    web/customer/portal/index.html \
    deployment/install_admin_console.sh \
    deployment/rollback_admin_console.sh \
    deployment/systemd_env.sh \
    deployment/vinted-ipv6.service \
    deployment/verify_ipv6_prefix.sh \
    release-files.sha256 \
    release-manifest.txt; do
    [[ -f "$payload_root/$required_path" &&
       ! -L "$payload_root/$required_path" ]] ||
      return 1
  done
  [[ -x "$payload_root/bin/vinted-ipv6-linux-amd64" ]] || return 1

  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      version)
        manifest_version="$value"
        (( version_count += 1 ))
        ;;
      commit)
        manifest_commit="$value"
        (( commit_count += 1 ))
        ;;
      binary_sha256)
        manifest_binary_sha="$value"
        (( binary_count += 1 ))
        ;;
      files_sha256)
        manifest_files_sha="$value"
        (( files_count += 1 ))
        ;;
      source_date_epoch)
        manifest_epoch="$value"
        (( epoch_count += 1 ))
        ;;
      *)
        return 1
        ;;
    esac
  done <"$payload_root/release-manifest.txt"
  (( version_count == 1 && commit_count == 1 && binary_count == 1 &&
     files_count == 1 && epoch_count == 1 )) || return 1
  [[ "$manifest_version" == "$expected_version" ]] || return 1
  [[ "$manifest_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$manifest_binary_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$manifest_files_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$manifest_epoch" =~ ^[0-9]+$ ]] || return 1

  files_sha="$(sha256sum "$payload_root/release-files.sha256" |
    awk '{print tolower($1)}')"
  [[ "$files_sha" == "$manifest_files_sha" ]] || return 1
  while read -r file_hash file_path || [[ -n "$file_hash$file_path" ]]; do
    (( file_index < ${#expected_files[@]} )) || return 1
    [[ "$file_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    file_path="${file_path#\*}"
    [[ "$file_path" == "${expected_files[$file_index]}" ]] || return 1
    [[ "$file_hash" == "$(
      sha256sum "$payload_root/$file_path" | awk '{print tolower($1)}'
    )" ]] || return 1
    (( file_index += 1 ))
  done <"$payload_root/release-files.sha256"
  (( file_index == ${#expected_files[@]} )) || return 1

  binary_sha="$(sha256sum "$payload_root/bin/vinted-ipv6-linux-amd64" |
    awk '{print tolower($1)}')"
  [[ "$binary_sha" == "$manifest_binary_sha" ]] || return 1
  version_output="$("$payload_root/bin/vinted-ipv6-linux-amd64" -version)"
  [[ "$version_output" == \
    "vinted-ipv6 $expected_version (${manifest_commit:0:12})" ]] || return 1
  bash -n "$payload_root"/deployment/*.sh || return 1

  VERIFIED_MANIFEST_COMMIT="$manifest_commit"
  VERIFIED_BINARY_SHA="$binary_sha"
}

read_service_value() {
  local key="$1" file="/etc/vinted-ipv6/service.env" value=""
  [[ -r "$file" ]] || return 1
  value="$(awk -F= -v wanted="$key" '
    $1 == wanted {
      value = substr($0, index($0, "=") + 1)
      if (value ~ /^"[^"]*"$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$file")"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

extract_default_interface() {
  awk '{
      for (field_index = 1; field_index <= NF; field_index++) {
        if ($field_index == "dev" && field_index < NF) {
          print $(field_index + 1)
          exit
        }
      }
    }'
}

detect_interface() {
  ip -4 route show default 2>/dev/null | extract_default_interface
}

detect_public_ipv4() {
  local value=""
  value="$(curl --noproxy '*' --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --fail --silent --show-error --connect-timeout 5 \
    --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if validate_ipv4 "$value"; then
    printf '%s\n' "$value"
    return
  fi
  ip -4 -o address show scope global 2>/dev/null |
    awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }'
}

detect_prefixes() {
  local network_interface="$1" route normalized result=""
  while IFS= read -r route; do
    normalized="$(normalize_prefix "$route" 2>/dev/null || true)"
    [[ -n "$normalized" ]] || continue
    if [[ ",$result," != *",$normalized,"* ]]; then
      result="${result:+$result,}$normalized"
    fi
  done < <(ip -6 route show dev "$network_interface" 2>/dev/null |
    awk '$1 ~ /\/48$/ { print $1 }')
  printf '%s\n' "$result"
}

open_prompt_tty() {
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    PROMPT_FD=3
  fi
}

prompt_value() {
  local variable_name="$1" label="$2" default_value="${3:-}" value=""
  if [[ -n "${!variable_name:-}" ]]; then
    return
  fi
  [[ -n "$PROMPT_FD" ]] ||
    die "$variable_name is required in non-interactive mode."
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value" >&"$PROMPT_FD"
  else
    printf '%s: ' "$label" >&"$PROMPT_FD"
  fi
  IFS= read -r -u "$PROMPT_FD" value
  printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_secret_twice() {
  local variable_name="$1" label="$2" first="" second=""
  if [[ -n "${!variable_name:-}" ]]; then
    return
  fi
  [[ -n "$PROMPT_FD" ]] ||
    die "$variable_name is required in non-interactive mode."
  while true; do
    printf '%s: ' "$label" >&"$PROMPT_FD"
    IFS= read -r -s -u "$PROMPT_FD" first
    printf '\nConfirm %s: ' "$label" >&"$PROMPT_FD"
    IFS= read -r -s -u "$PROMPT_FD" second
    printf '\n' >&"$PROMPT_FD"
    if [[ "$first" == "$second" ]]; then
      printf -v "$variable_name" '%s' "$first"
      return
    fi
    echo "Values did not match; try again." >&"$PROMPT_FD"
  done
}

prompt_yes_no() {
  local label="$1" default_answer="${2:-no}" answer=""
  if [[ -z "$PROMPT_FD" ]]; then
    [[ "$default_answer" == "yes" ]]
    return
  fi
  if [[ "$default_answer" == "yes" ]]; then
    printf '%s [Y/n]: ' "$label" >&"$PROMPT_FD"
  else
    printf '%s [y/N]: ' "$label" >&"$PROMPT_FD"
  fi
  IFS= read -r -u "$PROMPT_FD" answer
  answer="${answer,,}"
  [[ -z "$answer" ]] && answer="$default_answer"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

curl_download() {
  local url="$1" destination="$2"
  curl --noproxy '*' --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 300 \
    --output "$destination" "$url"
}

cleanup_quick_install() {
  local exit_code=$?
  trap - EXIT
  IPV6_ADMIN_PASSWORD=""
  IPV4_UPSTREAM_PASS=""
  unset IPV6_ADMIN_PASSWORD IPV4_UPSTREAM_PASS
  if [[ -n "$RELEASE_STAGE_DIR" && -d "$RELEASE_STAGE_DIR" ]]; then
    case "$RELEASE_STAGE_DIR" in
      /opt/vinted-ipv6/releases/.stage-*) rm -rf -- "$RELEASE_STAGE_DIR" ;;
    esac
  fi
  if [[ -n "$DOWNLOAD_WORK_DIR" && -d "$DOWNLOAD_WORK_DIR" ]]; then
    case "$DOWNLOAD_WORK_DIR" in
      /tmp/vinted-ipv6-download.*|\
      "${TMPDIR:-/tmp}"/vinted-ipv6-download.*)
        rm -rf -- "$DOWNLOAD_WORK_DIR"
        ;;
    esac
  fi
  exit "$exit_code"
}

usage() {
  cat <<'EOF'
Usage: bash quick_install.sh [options]

Options:
  --version vX.Y.Z             Install one fixed release (default: current pinned release)
  --repository OWNER/REPO      Public distribution repository
  --archive-sha256 HEX         Required unless embedded by the release builder
  --yes                        Accept the final confirmation
  --skip-ipv6-egress-check     Skip the real random /128 outbound test
  --public-domain DOMAIN       Use an existing DNS name for trusted HTTPS
  --skip-trusted-https         Keep only the self-signed :8443 fallback
  --allow-downgrade            Permit an older version (requires confirmation)
  --help                       Show this help

All installation values can also be supplied through the existing IPV6_* and
IPV4_UPSTREAM_* environment variables for controlled non-interactive use.
EOF
}

main() {
  local version="${VINTED_IPV6_VERSION:-$DEFAULT_VERSION}"
  local distribution_repository="$DEFAULT_DISTRIBUTION_REPOSITORY"
  local archive_sha256_pin="${VINTED_IPV6_ARCHIVE_SHA256:-$DEFAULT_ARCHIVE_SHA256}"
  local assume_yes="${VINTED_IPV6_ASSUME_YES:-0}"
  local skip_egress_check="${VINTED_IPV6_SKIP_EGRESS_CHECK:-0}"
  local trusted_https="${VINTED_IPV6_TRUSTED_HTTPS:-1}"
  local public_domain="${IPV6_PUBLIC_DOMAIN:-}"
  local allow_downgrade="${VINTED_IPV6_ALLOW_DOWNGRADE:-0}"
  local current_install=0 installed_version="" default_value=""
  local admin_status="" existing_listen="" existing_reserved=""
  local configure_upstream="${VINTED_IPV6_CONFIGURE_UPSTREAM:-}"
  local archive_name checksum_name release_base archive_url checksum_url
  local archive_path checksum_path expected_sha actual_sha expected_count
  local root_name extract_dir payload_root
  local package_sha release_dir random_hex test_address
  local admin_url install_exit trusted_https_ready=0 tls_backup=""

  while (( $# > 0 )); do
    case "$1" in
      --version)
        (( $# >= 2 )) || die "--version requires a value."
        version="$2"
        shift 2
        ;;
      --repository)
        (( $# >= 2 )) || die "--repository requires OWNER/REPO."
        distribution_repository="$2"
        shift 2
        ;;
      --archive-sha256)
        (( $# >= 2 )) || die "--archive-sha256 requires a value."
        archive_sha256_pin="${2,,}"
        shift 2
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      --skip-ipv6-egress-check)
        skip_egress_check=1
        shift
        ;;
      --public-domain)
        (( $# >= 2 )) || die "--public-domain requires a value."
        public_domain="${2,,}"
        shift 2
        ;;
      --skip-trusted-https)
        trusted_https=0
        shift
        ;;
      --allow-downgrade)
        allow_downgrade=1
        shift
        ;;
      --help|-h)
        usage
        return
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  (( EUID == 0 )) || die "Run this installer from a root shell."
  [[ -d /run/systemd/system ]] || die "This installer requires systemd."
  [[ "$(uname -m)" == "x86_64" ]] ||
    die "Only Linux x86_64 is supported; found $(uname -m)."
  validate_version "$version" || die "Invalid release version: $version"
  validate_repository "$distribution_repository" ||
    die "Invalid distribution repository: $distribution_repository"
  validate_archive_sha256_pin "$archive_sha256_pin" ||
    die "This installer is not release-pinned; use a generated installer or supply --archive-sha256 with exactly 64 hexadecimal characters."
  archive_sha256_pin="${archive_sha256_pin,,}"
  validate_boolean "$trusted_https" ||
    die "VINTED_IPV6_TRUSTED_HTTPS must be 0 or 1."

  for command_name in \
    awk bash chmod cmp cp curl flock grep install ip mktemp mv openssl rm \
    sha256sum sort ss stat systemctl tar uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "Required command is missing: $command_name"
  done

  umask 077
  open_prompt_tty
  trap cleanup_quick_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 8>/run/lock/vinted-ipv6-quick-install.lock
  flock -n 8 ||
    die "Another one-click installation or upgrade is already running."

  if [[ -s /var/lib/vinted-ipv6/vinted-ipv6.db ]]; then
    current_install=1
    if [[ -x /usr/local/bin/vinted-ipv6 ]]; then
      admin_status="$(
        /usr/local/bin/vinted-ipv6 \
          -data-dir /var/lib/vinted-ipv6 -admin-status 2>/dev/null || true
      )"
      case "$admin_status" in
        present) current_install=1 ;;
        missing) current_install=0 ;;
      esac
    else
      current_install=0
    fi
  fi
  if [[ -x /usr/local/bin/vinted-ipv6 ]]; then
    installed_version="$(
      /usr/local/bin/vinted-ipv6 -version 2>/dev/null |
        awk 'NR == 1 { print $2 }'
    )"
    if validate_version "$installed_version" &&
       version_is_older "$version" "$installed_version" &&
       [[ "$allow_downgrade" != "1" ]]; then
      die "Refusing downgrade from $installed_version to $version without --allow-downgrade."
    fi
  fi

  default_value="$(read_service_value IPV6_INTERFACE 2>/dev/null || true)"
  default_value="${default_value:-$(detect_interface)}"
  if (( current_install == 1 )); then
    IPV6_INTERFACE="${IPV6_INTERFACE:-$default_value}"
  else
    prompt_value IPV6_INTERFACE "IPv6 network interface" "$default_value"
  fi
  [[ "$IPV6_INTERFACE" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] ||
    die "Invalid network interface name."
  ip link show dev "$IPV6_INTERFACE" >/dev/null 2>&1 ||
    die "Network interface does not exist: $IPV6_INTERFACE"

  default_value="$(detect_public_ipv4)"
  if (( current_install == 1 )); then
    IPV6_PUBLIC_IPV4="${IPV6_PUBLIC_IPV4:-$default_value}"
  else
    prompt_value IPV6_PUBLIC_IPV4 "Public IPv4 address" "$default_value"
  fi
  validate_ipv4 "$IPV6_PUBLIC_IPV4" ||
    die "Invalid public IPv4 address: $IPV6_PUBLIC_IPV4"
  if [[ "$trusted_https" == "1" ]]; then
    if [[ -z "$public_domain" ]]; then
      public_domain="$(derive_sslip_domain "$IPV6_PUBLIC_IPV4")"
    fi
    public_domain="${public_domain,,}"
    validate_public_domain "$public_domain" ||
      die "Invalid trusted HTTPS domain: $public_domain"
    # Keep proxy/export URLs on the raw IPv4 fallback until certificate
    # issuance and the external health check both succeed.
    IPV6_PUBLIC_HOST="$IPV6_PUBLIC_IPV4"
  else
    IPV6_PUBLIC_HOST="$IPV6_PUBLIC_IPV4"
  fi

  default_value="$(detect_prefixes "$IPV6_INTERFACE")"
  if (( current_install == 1 )); then
    IPV6_PREFIXES="${IPV6_PREFIXES:-$default_value}"
  else
    prompt_value IPV6_PREFIXES "Routed IPv6 /48 prefix(es), comma-separated" \
      "$default_value"
  fi
  IPV6_PREFIXES="$(normalize_prefix_list "$IPV6_PREFIXES")" ||
    die "Each IPv6 prefix must contain exactly three hexadecimal groups."
  local prefix
  local -a prefix_values
  IFS=',' read -r -a prefix_values <<<"$IPV6_PREFIXES"
  for prefix in "${prefix_values[@]}"; do
    ip -6 route show exact "$prefix::/48" dev "$IPV6_INTERFACE" |
      grep -q . ||
      die "No exact route for $prefix::/48 on $IPV6_INTERFACE."
  done

  existing_listen="$(read_service_value IPV6_LISTEN 2>/dev/null || true)"
  default_value="${existing_listen#:}"
  if (( current_install == 1 )); then
    IPV6_MANAGEMENT_PORT="${default_value:-}"
    [[ -n "$IPV6_MANAGEMENT_PORT" ]] ||
      die "Existing service environment does not contain IPV6_LISTEN."
  else
    prompt_value IPV6_MANAGEMENT_PORT "Management HTTPS port" \
      "${default_value:-8443}"
  fi
  validate_port "$IPV6_MANAGEMENT_PORT" ||
    die "Invalid management port."
  IPV6_LISTEN=":$IPV6_MANAGEMENT_PORT"

  if (( current_install == 1 )); then
    IPV6_PORT_MIN="${IPV6_PORT_MIN:-1000}"
    IPV6_PORT_MAX="${IPV6_PORT_MAX:-59999}"
  else
    prompt_value IPV6_PORT_MIN "First proxy port" "${IPV6_PORT_MIN:-1000}"
    prompt_value IPV6_PORT_MAX "Last proxy port" "${IPV6_PORT_MAX:-59999}"
  fi
  validate_proxy_port_range "$IPV6_PORT_MIN" "$IPV6_PORT_MAX" ||
    die "Proxy ports must be within 1000-65535 and ordered."

  if (( current_install == 1 )); then
    IPV6_SUBNET_START="${IPV6_SUBNET_START:-1}"
  else
    prompt_value IPV6_SUBNET_START "First /64 subnet (hexadecimal)" \
      "${IPV6_SUBNET_START:-1}"
  fi
  validate_subnet_start "$IPV6_SUBNET_START" ||
    die "Invalid hexadecimal /64 subnet start."

  existing_reserved="$(
    read_service_value IPV6_RESERVED_PORTS 2>/dev/null || true
  )"
  default_value="$existing_reserved"
  if (( current_install == 1 )); then
    IPV6_RESERVED_PORTS="$(
      remove_reserved_port "$existing_reserved" "$IPV6_MANAGEMENT_PORT"
    )"
  elif [[ -z "$default_value" ]]; then
    default_value="22,53"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      local ssh_port
      ssh_port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
      if validate_port "$ssh_port" && [[ ",$default_value," != *",$ssh_port,"* ]]; then
        default_value="$default_value,$ssh_port"
      fi
    fi
    prompt_value IPV6_RESERVED_PORTS "Reserved local service ports" "$default_value"
  else
    prompt_value IPV6_RESERVED_PORTS "Reserved local service ports" "$default_value"
  fi
  validate_reserved_ports "$IPV6_RESERVED_PORTS" ||
    die "Reserved ports must be comma-separated values from 1 to 65535."

  default_value="$(read_service_value IPV6_ADMIN_PATH 2>/dev/null || true)"
  if (( current_install == 1 )); then
    IPV6_ADMIN_PATH="${IPV6_ADMIN_PATH:-$default_value}"
    [[ -n "$IPV6_ADMIN_PATH" ]] ||
      die "Existing service environment does not contain IPV6_ADMIN_PATH."
  else
    default_value="${default_value:-/console-$(openssl rand -hex 16)}"
    prompt_value IPV6_ADMIN_PATH "Private management path" "$default_value"
  fi
  validate_admin_path "$IPV6_ADMIN_PATH" ||
    die "Invalid or reserved private management path."

  if (( current_install == 0 )); then
    prompt_value IPV6_ADMIN_USER "Initial administrator username" \
      "${IPV6_ADMIN_USER:-alongya}"
    contains_line_break "$IPV6_ADMIN_USER" &&
      die "Administrator username must not contain line breaks."
    [[ -n "$IPV6_ADMIN_USER" ]] || die "Administrator username is required."
    prompt_secret_twice IPV6_ADMIN_PASSWORD "Initial administrator password"
    contains_line_break "$IPV6_ADMIN_PASSWORD" &&
      die "Administrator password must not contain line breaks."
    (( ${#IPV6_ADMIN_PASSWORD} >= 8 && ${#IPV6_ADMIN_PASSWORD} <= 72 )) ||
      die "Administrator password must contain 8-72 characters."

    if [[ -z "$configure_upstream" ]]; then
      if [[ -n "${IPV4_UPSTREAM_HOST:-}" ]] ||
         prompt_yes_no "Configure the IPv4 SOCKS5 upstream now?" no; then
        configure_upstream=1
      else
        configure_upstream=0
      fi
    fi
    if [[ "$configure_upstream" == "1" ]]; then
      prompt_value IPV4_UPSTREAM_HOST "Upstream host" ""
      prompt_value IPV4_UPSTREAM_PORT "Upstream port" \
        "${IPV4_UPSTREAM_PORT:-1080}"
      prompt_value IPV4_UPSTREAM_USER "Upstream username or SID template" ""
      if [[ -z "${IPV4_UPSTREAM_PASS:-}" ]]; then
        [[ -n "$PROMPT_FD" ]] ||
          die "IPV4_UPSTREAM_PASS is required in non-interactive mode."
        printf 'Upstream password: ' >&"$PROMPT_FD"
        IFS= read -r -s -u "$PROMPT_FD" IPV4_UPSTREAM_PASS
        printf '\n' >&"$PROMPT_FD"
      fi
      [[ -n "$IPV4_UPSTREAM_HOST" ]] || die "Upstream host is required."
      validate_port "$IPV4_UPSTREAM_PORT" || die "Invalid upstream port."
      contains_line_break "$IPV4_UPSTREAM_HOST$IPV4_UPSTREAM_USER$IPV4_UPSTREAM_PASS" &&
        die "Upstream values must not contain line breaks."
      (( ${#IPV4_UPSTREAM_HOST} <= 255 &&
         ${#IPV4_UPSTREAM_USER} <= 255 &&
         ${#IPV4_UPSTREAM_PASS} <= 255 )) ||
        die "SOCKS5 upstream host and credentials must not exceed 255 characters."
    fi
  else
    IPV6_ADMIN_USER=""
    IPV6_ADMIN_PASSWORD=""
    configure_upstream=0
  fi
  [[ "$configure_upstream" == "0" || "$configure_upstream" == "1" ]] ||
    die "VINTED_IPV6_CONFIGURE_UPSTREAM must be 0 or 1."

  echo
  echo "Vinted IPv6 installation summary"
  echo "  Release:          $version"
  [[ -n "$installed_version" ]] &&
    echo "  Installed:        $installed_version"
  echo "  Public IPv4:      $IPV6_PUBLIC_IPV4"
  if [[ "$trusted_https" == "1" ]]; then
    echo "  Trusted domain:   $public_domain"
  else
    echo "  Trusted HTTPS:    disabled"
  fi
  echo "  IPv6 interface:   $IPV6_INTERFACE"
  if [[ "$trusted_https" == "1" ]]; then
    echo "  Management URL:   https://$public_domain$IPV6_ADMIN_PATH/"
  else
    echo "  Management URL:   https://$IPV6_PUBLIC_IPV4$IPV6_LISTEN$IPV6_ADMIN_PATH/"
  fi
  echo "  Reserved ports:   $IPV6_RESERVED_PORTS"
  if (( current_install == 1 )); then
    echo "  Database settings: preserve IPv6 pools, ports, users, traffic, and upstream"
    echo "  Route prerequisite: $IPV6_PREFIXES"
  else
    echo "  IPv6 /48 pools:   $IPV6_PREFIXES"
    echo "  Proxy ports:      $IPV6_PORT_MIN-$IPV6_PORT_MAX"
    echo "  First /64 subnet: $IPV6_SUBNET_START (hexadecimal)"
  fi
  if [[ "$configure_upstream" == "1" ]]; then
    echo "  IPv4 upstream:    $IPV4_UPSTREAM_HOST:$IPV4_UPSTREAM_PORT"
  elif (( current_install == 1 )); then
    echo "  IPv4 upstream:    preserve existing database setting"
  else
    echo "  IPv4 upstream:    configure later in the console"
  fi
  echo

  if [[ "$assume_yes" != "1" ]] &&
     ! prompt_yes_no "Download, verify, and install this release?" no; then
    die "Installation cancelled."
  fi

  archive_name="vinted-ipv6-$version-linux-amd64.tar.gz"
  checksum_name="SHA256SUMS-$version.txt"
  release_base="https://github.com/$distribution_repository/releases/download/$version"
  archive_url="$release_base/$archive_name"
  checksum_url="$release_base/$checksum_name"
  DOWNLOAD_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vinted-ipv6-download.XXXXXXXX")"
  archive_path="$DOWNLOAD_WORK_DIR/$archive_name"
  checksum_path="$DOWNLOAD_WORK_DIR/$checksum_name"
  curl_download "$checksum_url" "$checksum_path"
  curl_download "$archive_url" "$archive_path"

  read -r expected_count expected_sha < <(awk -v name="$archive_name" '
    $1 ~ /^[0-9a-fA-F]{64}$/ && ($2 == name || $2 == "*" name) {
      count += 1
      value = tolower($1)
    }
    END {
      print count + 0, (count == 1 ? value : "")
    }
  ' "$checksum_path")
  [[ "$expected_count" == "1" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "Release checksum manifest is invalid or ambiguous."
  actual_sha="$(sha256sum "$archive_path" | awk '{print tolower($1)}')"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    die "Release archive SHA-256 verification failed."
  [[ "$actual_sha" == "$archive_sha256_pin" ]] ||
    die "Release archive does not match the SHA-256 pinned by this installer."
  package_sha="$actual_sha"

  root_name="vinted-ipv6-$version"
  validate_archive_entries "$archive_path" "$root_name" ||
    die "Release archive contains an unsafe path or file type."
  extract_dir="$DOWNLOAD_WORK_DIR/extracted"
  install -d -m 0700 "$extract_dir"
  tar --no-same-owner --no-same-permissions -xzf "$archive_path" -C "$extract_dir"
  payload_root="$extract_dir/$root_name"
  verify_payload "$payload_root" "$version" ||
    die "Release payload or manifest verification failed."

  install -d -m 0755 /opt/vinted-ipv6/releases
  release_dir="/opt/vinted-ipv6/releases/$version"
  if [[ -e "$release_dir" ]]; then
    [[ -f "$release_dir/package.sha256" ]] ||
      die "Existing release directory is not managed by this installer: $release_dir"
    [[ "$(<"$release_dir/package.sha256")" == "$package_sha" ]] ||
      die "Existing release directory has a different package checksum."
    cmp -s \
      "$payload_root/release-manifest.txt" \
      "$release_dir/release-manifest.txt" ||
      die "Existing retained release manifest differs from the verified package."
    cmp -s \
      "$payload_root/release-files.sha256" \
      "$release_dir/release-files.sha256" ||
      die "Existing retained file manifest differs from the verified package."
    verify_payload "$release_dir" "$version" ||
      die "Existing retained release failed integrity verification."
  else
    RELEASE_STAGE_DIR="$(mktemp -d \
      "/opt/vinted-ipv6/releases/.stage-$version.XXXXXXXX")"
    cp -a "$payload_root/." "$RELEASE_STAGE_DIR/"
    printf '%s\n' "$package_sha" >"$RELEASE_STAGE_DIR/package.sha256"
    chmod 0644 "$RELEASE_STAGE_DIR/package.sha256"
    mv "$RELEASE_STAGE_DIR" "$release_dir"
    RELEASE_STAGE_DIR=""
  fi

  if [[ "$skip_egress_check" != "1" && "$current_install" == "0" ]]; then
    for prefix in "${prefix_values[@]}"; do
      random_hex="$(openssl rand -hex 8)"
      test_address="$prefix:fffe:${random_hex:0:4}:${random_hex:4:4}:${random_hex:8:4}:${random_hex:12:4}"
      IPV6_INTERFACE="$IPV6_INTERFACE" \
        IPV6_TEST_ADDRESS="$test_address" \
        bash "$release_dir/deployment/verify_ipv6_prefix.sh"
    done
  fi

  set +e
  (
    unset BINARY_PATH WEB_SOURCE SERVICE_SOURCE ROLLBACK_SOURCE
    export \
      IPV6_PUBLIC_IPV4 IPV6_PREFIXES IPV6_INTERFACE IPV6_LISTEN \
      IPV6_PUBLIC_HOST \
      IPV6_PORT_MIN IPV6_PORT_MAX IPV6_SUBNET_START IPV6_ADMIN_PATH \
      IPV6_RESERVED_PORTS IPV6_ADMIN_USER IPV6_ADMIN_PASSWORD
    if [[ "$configure_upstream" == "1" ]]; then
      export \
        IPV4_UPSTREAM_HOST IPV4_UPSTREAM_PORT IPV4_UPSTREAM_USER \
        IPV4_UPSTREAM_PASS
    else
      unset \
        IPV4_UPSTREAM_HOST IPV4_UPSTREAM_PORT IPV4_UPSTREAM_USER \
        IPV4_UPSTREAM_PASS
    fi
    exec bash "$release_dir/deployment/install_admin_console.sh"
  )
  install_exit=$?
  set -e
  IPV6_ADMIN_PASSWORD=""
  IPV4_UPSTREAM_PASS=""
  unset IPV6_ADMIN_PASSWORD IPV4_UPSTREAM_PASS
  (( install_exit == 0 )) || exit "$install_exit"

  if [[ "$trusted_https" == "1" ]]; then
    echo
    echo "Configuring trusted HTTPS for $public_domain ..."
    if configure_trusted_https \
        "$IPV6_PUBLIC_IPV4" "$public_domain" "$IPV6_MANAGEMENT_PORT"; then
      trusted_https_ready=1
      tls_backup="$(</var/lib/vinted-ipv6/tls-proxy-last-backup)"
      admin_url="https://$public_domain$IPV6_ADMIN_PATH/"
    else
      echo "WARNING: Trusted HTTPS setup did not complete." >&2
      echo "The proxy service remains installed and available through the self-signed fallback." >&2
      admin_url="https://$IPV6_PUBLIC_IPV4$IPV6_LISTEN$IPV6_ADMIN_PATH/"
    fi
  else
    admin_url="https://$IPV6_PUBLIC_IPV4$IPV6_LISTEN$IPV6_ADMIN_PATH/"
  fi
  echo
  echo "Verified release installed successfully."
  echo "Version: $(/usr/local/bin/vinted-ipv6 -version)"
  echo "Package SHA-256: $package_sha"
  echo "Admin console: $admin_url"
  if (( trusted_https_ready == 1 )); then
    echo "Buyer console: https://$public_domain/client/"
    echo "Trusted HTTPS backup: $tls_backup"
    echo "Let's Encrypt renewal: certbot.timer"
  fi
  echo "TLS certificate fingerprint:"
  openssl x509 -in /etc/vinted-ipv6/tls/server.crt -noout \
    -fingerprint -sha256
  if (( trusted_https_ready == 1 )); then
    echo "Open TCP ports 80 and 443 plus the required proxy ports"
    echo "in your provider firewall. Port $IPV6_MANAGEMENT_PORT is only the emergency fallback."
  else
    echo "Open management port $IPV6_MANAGEMENT_PORT and the required proxy ports"
    echo "in your provider firewall; this installer does not change provider firewall rules."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
