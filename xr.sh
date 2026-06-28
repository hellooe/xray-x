#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

XR_DIR="$HOME/xr"
XRAY_BIN="$XR_DIR/xray"
CONFIG_DIR="$XR_DIR/config"
LOG_DIR="$XR_DIR/logs"
XRAY_JSON="$CONFIG_DIR/config.json"
REALITY_KEY_DIR="$XR_DIR/reality"
INBOUNDS_DIR="$CONFIG_DIR/inbounds"
OUTBOUNDS_DIR="$CONFIG_DIR/outbounds"
ROUTES_DIR="$CONFIG_DIR/routes"
CERTS_DIR="$XR_DIR/certs"
ENC_DIR="$XR_DIR/encryption"
XR_CONF_FILE="$XR_DIR/env.conf"

save_config() {
    local var="$1" value="$2"
    mkdir -p "$XR_DIR"
    if [[ -f "$XR_CONF_FILE" ]]; then
        if grep -q "^$var=" "$XR_CONF_FILE"; then
            sed -i "s|^$var=.*|$var=$value|" "$XR_CONF_FILE"
        else
            echo "$var=$value" >> "$XR_CONF_FILE"
        fi
    else
        echo "$var=$value" > "$XR_CONF_FILE"
        chmod 600 "$XR_CONF_FILE"
    fi
}

get_or_ask() {
    local var="$1" prompt="$2" default="$3"
    local value=""
    eval "value=\${$var:-}"
    if [[ -n "$value" ]]; then
        save_config "$var" "$value"
        echo "$value"
        return 0
    fi
    if [[ -f "$XR_CONF_FILE" ]]; then
        value=$(grep -E "^$var=" "$XR_CONF_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi
    read -p "$prompt: " value
    [[ -z "$value" ]] && value="$default"
    save_config "$var" "$value"
    echo "$value"
}

get_arch() {
    case $(uname -m) in
        arm64|aarch64) echo "arm64" ;;
        amd64|x86_64) echo "amd64" ;;
        *) echo "unsupported" ;;
    esac
}

install_deps() {
    echo -e "${YELLOW}安装依赖...${NC}"
    apk update >/dev/null 2>&1 && apk add curl wget unzip openssl jq >/dev/null 2>&1 && return 0
    apt update -y >/dev/null 2>&1 && apt install -y curl wget unzip openssl jq >/dev/null 2>&1 && return 0
    yum install -y curl wget unzip openssl jq >/dev/null 2>&1 && return 0
    echo -e "${RED}无法安装依赖，请手动安装 curl wget unzip openssl jq${NC}"
    exit 1
}

generate_uuid() {
    local uuid=$("$XRAY_BIN" uuid 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        echo -e "${RED}无法生成 UUID，请确保 Xray 已安装${NC}" >&2
        exit 1
    fi
    echo "$uuid"
}

generate_reality_key() {
    mkdir -p "$REALITY_KEY_DIR"
    if [[ ! -f "$REALITY_KEY_DIR/private_key" ]]; then
        if [[ ! -f "$XRAY_BIN" ]]; then
            echo -e "${RED}Xray 未安装${NC}" >&2
            return 1
        fi
        local key_pair=$("$XRAY_BIN" x25519)
        local private_key=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
        local public_key=$(echo "$key_pair" | awk -F':' '/PublicKey/ {print $2}' | xargs)
        echo "$private_key" > "$REALITY_KEY_DIR/private_key"
        echo "$public_key" > "$REALITY_KEY_DIR/public_key"
        echo "$(date +%s%N | sha256sum | cut -c 1-8)" > "$REALITY_KEY_DIR/short_id"
    fi
    cat "$REALITY_KEY_DIR/private_key"
}

cloudflare_get_origin_cert() {
    local domain="$1" email="$2" api_key="$3" zone_id="$4" cert_file="$5" key_file="$6"
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/origin_certificates" \
        -H "X-Auth-Email: ${email}" \
        -H "X-Auth-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"hostnames\":[\"${domain}\"],\"validity\":365,\"requested_validity\":365}")
    local success=$(echo "$response" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        echo -e "${RED}获取证书失败: $(echo "$response" | jq -r '.errors[0].message')${NC}"
        return 1
    fi
    echo "$response" | jq -r '.result.certificate' > "$cert_file"
    echo "$response" | jq -r '.result.private_key' > "$key_file"
    chmod 600 "$key_file"
    echo -e "${GREEN}证书已保存${NC}"
}

cloudflare_create_origin_rule() {
    local domain="$1" path="$2" port="$3" email="$4" api_key="$5" zone_id="$6"
    local pattern="http.host eq \"${domain}\" and http.path eq \"${path}\""
    local actions='[{"id":"destination_port","value":'${port}'}]'
    local data="{\"pattern\":\"${pattern}\",\"actions\":${actions}}"
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/origin_rules" \
        -H "X-Auth-Email: ${email}" \
        -H "X-Auth-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "$data")
    local success=$(echo "$response" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        echo -e "${RED}创建 Origin Rule 失败: $(echo "$response" | jq -r '.errors[0].message')${NC}"
        return 1
    fi
    echo -e "${GREEN}Origin Rule 创建成功: ${domain}${path} -> ${port}${NC}"
}

service_control() {
    local action=$1
    case $action in
        start)
            if [[ ! -f "$XRAY_BIN" || ! -f "$XRAY_JSON" ]]; then
                echo -e "${RED}Xray 未安装或配置不存在${NC}" >&2
                return 1
            fi
            if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
                cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
command="$XRAY_BIN"
command_args="run -c $XRAY_JSON"
command_user="root"
pidfile="/run/xray.pid"
command_background=true
depend() { need net; }
EOF
                chmod +x /etc/init.d/xray
                rc-service xray start >/dev/null 2>&1
                rc-update add xray default >/dev/null 2>&1
            elif command -v systemctl >/dev/null 2>&1; then
                cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -c $XRAY_JSON
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable xray >/dev/null 2>&1
                systemctl start xray
            else
                nohup "$XRAY_BIN" run -c "$XRAY_JSON" > "$LOG_DIR/xray.log" 2>&1 &
            fi
            ;;
        stop)
            if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/xray ]; then
                rc-service xray stop >/dev/null 2>&1
                rc-update del xray default >/dev/null 2>&1
            elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xray 2>/dev/null; then
                systemctl stop xray
                systemctl disable xray >/dev/null 2>&1
            else
                pkill -f "xray run" 2>/dev/null
            fi
            ;;
        restart)
            service_control stop
            sleep 1
            service_control start
            ;;
        status)
            if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/xray ]; then
                rc-service xray status 2>/dev/null
            elif command -v systemctl >/dev/null 2>&1; then
                systemctl status xray --no-pager 2>/dev/null || echo -e "${RED}未运行${NC}"
            else
                if pgrep -f "xray run" >/dev/null; then
                    echo -e "${GREEN}运行中 (nohup)${NC}"
                else
                    echo -e "${RED}已停止${NC}"
                fi
            fi
            ;;
    esac
}

merge_json_files() {
    local dir=$1
    local files=("$dir"/*.json)
    if [[ ${#files[@]} -eq 0 ]] || [[ ! -f "${files[0]}" ]]; then
        echo "[]"
        return
    fi
    jq -s '.' "${files[@]}" 2>/dev/null || echo "[]"
}

generate_config() {
    echo -e "${BLUE}生成配置${NC}"
    mkdir -p "$CONFIG_DIR" "$INBOUNDS_DIR" "$OUTBOUNDS_DIR" "$ROUTES_DIR"

    if [[ ! "$(ls -A "$INBOUNDS_DIR" 2>/dev/null)" ]]; then
        echo -e "${RED}没有入站配置${NC}"
        return 1
    fi
    if [[ ! "$(ls -A "$OUTBOUNDS_DIR" 2>/dev/null)" ]]; then
        echo -e "${RED}没有出站配置${NC}"
        return 1
    fi

    local inbounds_json=$(merge_json_files "$INBOUNDS_DIR")
    local outbounds_json=$(merge_json_files "$OUTBOUNDS_DIR")
    local routes_json=$(merge_json_files "$ROUTES_DIR")
    [[ "$routes_json" = "[]" ]] && routes_json="[]"

    local temp_json=$(mktemp)
    cat > "$temp_json" <<EOF
{
    "log": {"loglevel": "warning", "access": "$LOG_DIR/access.log", "error": "$LOG_DIR/error.log"},
    "inbounds": $inbounds_json,
    "outbounds": $outbounds_json,
    "routing": {"domainStrategy": "AsIs", "rules": $routes_json}
}
EOF

    if [[ ! -x "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray 未安装，无法验证配置${NC}"
        rm -f "$temp_json"
        return 1
    fi

    if ! "$XRAY_BIN" run -c "$temp_json" -test >/dev/null 2>&1; then
        echo -e "${RED}配置验证失败，请检查各组件文件${NC}"
        rm -f "$temp_json"
        return 1
    fi

    mv "$temp_json" "$XRAY_JSON"
    echo -e "${GREEN}配置生成成功${NC}"
}

add_inbound() {
    echo -e "${BLUE}添加入站${NC}"
    local proto=$(get_or_ask "INBOUND_PROTO" "协议 [1=tcp+reality, 2=tcp+enc, 3=xhttp+tls" "1")
    local port=$(get_or_ask "INBOUND_PORT" "端口" "443")
    local uuid=$(get_or_ask "INBOUND_UUID" "UUID (留空自动)" "")
    [[ -z "$uuid" ]] && uuid=$(generate_uuid)

    local tag=""
    local inbound_file="$INBOUNDS_DIR/inbound-${port}.json"

    case $proto in
        1)  # reality
            local dest_domain=$(get_or_ask "REALITY_DEST" "目标域名" "www.bing.com")
            local private_key
            private_key=$(generate_reality_key)
            if [[ $? -ne 0 || -z "$private_key" ]]; then
                echo -e "${RED}生成 Reality 密钥失败，请检查 Xray 是否安装${NC}"
                return 1
            fi
            local short_id=$(cat "$REALITY_KEY_DIR/short_id" 2>/dev/null || echo "12345678")
            tag="vless-reality-${port}"
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg uuid "$uuid" \
                --arg dest "$dest_domain" \
                --arg privateKey "$private_key" \
                --arg shortId "$short_id" \
                '{
                    tag: $tag,
                    listen: "0.0.0.0",
                    port: ($port | tonumber),
                    protocol: "vless",
                    settings: {
                        clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "tcp",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            dest: ($dest + ":443"),
                            xver: 0,
                            serverNames: [$dest],
                            privateKey: $privateKey,
                            shortIds: [$shortId]
                        }
                    },
                    sniffing: {enabled: true, destOverride: ["http","tls"]}
                }' > "$inbound_file"
            ;;
        2)  # post-quantum
            local vlessenc_output=$("$XRAY_BIN" vlessenc 2>/dev/null)
            local decryption=$(echo "$vlessenc_output" | sed -n '/Authentication: ML-KEM-768/,/^$/ { /"decryption":/ s/.*"decryption": "\([^"]*\)".*/\1/p }' | head -1)
            local encryption=$(echo "$vlessenc_output" | sed -n '/Authentication: ML-KEM-768/,/^$/ { /"encryption":/ s/.*"encryption": "\([^"]*\)".*/\1/p }' | head -1)
            [[ -z "$decryption" ]] && decryption="none"
            [[ -z "$encryption" ]] && encryption="none"
            mkdir -p "$ENC_DIR"
            echo "$encryption" > "$ENC_DIR/inbound-${port}.enc"
            tag="vless-enc-${port}"
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg uuid "$uuid" \
                --arg decryption "$decryption" \
                '{
                    tag: $tag,
                    listen: "0.0.0.0",
                    port: ($port | tonumber),
                    protocol: "vless",
                    settings: {
                        clients: [{id: $uuid}],
                        decryption: $decryption
                    },
                    streamSettings: {
                        network: "tcp",
                        security: "none",
                        tcpSettings: {header: {type: "none"}}
                    },
                    sniffing: {enabled: true, destOverride: ["http","tls"]}
                }' > "$inbound_file"
            ;;
        3)  # xhttp+tls
            local domain=$(get_or_ask "DOMAIN" "域名" "")
            local path=$(get_or_ask "XHTTP_PATH" "路径" "/api/")
            tag="vless-xhttp-${port}"
            local security="none"
            local security_block="{}"
            if [[ -n "$domain" ]]; then
                local cf_enable=$(get_or_ask "CF_ENABLE" "启用 CF 增强? (y/N)" "n")
                if [[ "$cf_enable" =~ ^[Yy]$ ]]; then
                    local cf_email=$(get_or_ask "CF_EMAIL" "CF 邮箱" "")
                    local cf_key=$(get_or_ask "CF_GLOBAL_KEY" "CF Global API Key" "")
                    local cf_zone=$(get_or_ask "CF_ZONE_ID" "CF Zone ID" "")
                    if [[ -n "$cf_email" && -n "$cf_key" && -n "$cf_zone" ]]; then
                        mkdir -p "$CERTS_DIR"
                        local cert_file="$CERTS_DIR/${domain}.crt"
                        local key_file="$CERTS_DIR/${domain}.key"
                        cloudflare_get_origin_cert "$domain" "$cf_email" "$cf_key" "$cf_zone" "$cert_file" "$key_file" || return 1
                        cloudflare_create_origin_rule "$domain" "$path" "$port" "$cf_email" "$cf_key" "$cf_zone" || return 1
                        security="tls"
                        security_block="{\"serverName\": \"$domain\", \"certificates\": [{\"certificateFile\": \"$cert_file\",\"keyFile\": \"$key_file\"}]}"
                    else
                        echo -e "${YELLOW}CF 信息不完整，跳过增强${NC}"
                    fi
                fi
            fi
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg uuid "$uuid" \
                --arg path "$path" \
                --arg security "$security" \
                --argjson tlsSettings "$security_block" \
                '{
                    tag: $tag,
                    listen: "0.0.0.0",
                    port: ($port | tonumber),
                    protocol: "vless",
                    settings: {
                        clients: [{id: $uuid}],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "xhttp",
                        security: $security,
                        tlsSettings: $tlsSettings,
                        xhttpSettings: {path: $path, mode: "stream-one"}
                    },
                    sniffing: {enabled: true, destOverride: ["http","tls"]}
                }' > "$inbound_file"
            ;;
        *)
            echo -e "${RED}未知协议${NC}"
            return 1
            ;;
    esac
    echo -e "${GREEN}入站已添加: $tag${NC}"
}

add_outbound() {
    echo -e "${BLUE}添加出站${NC}"
    local type=$(get_or_ask "OUTBOUND_TYPE" "类型 [1=vless, 2=socks, 3=wireguard]" "1")
    local default_tag="outbound-$(date +%s)"
    local tag=$(get_or_ask "OUTBOUND_TAG" "标签" "$default_tag")
    local address=$(get_or_ask "OUTBOUND_ADDRESS" "地址" "")
    local port=$(get_or_ask "OUTBOUND_PORT" "端口" "")
    local out_file="$OUTBOUNDS_DIR/${tag}.json"

    case $type in
        1)  # vless+reality
            if [[ -z "$address" || -z "$port" ]]; then
                echo -e "${RED}地址和端口不能为空${NC}"
                return 1
            fi
            local uuid=$(get_or_ask "OUTBOUND_UUID" "UUID" "")
            local serverName=$(get_or_ask "OUTBOUND_SERVERNAME" "serverName" "")
            local publicKey=$(get_or_ask "OUTBOUND_PUBLICKEY" "publicKey" "")
            local shortId=$(get_or_ask "OUTBOUND_SHORTID" "shortId" "")
            if [[ -z "$uuid" || -z "$serverName" || -z "$publicKey" || -z "$shortId" ]]; then
                echo -e "${RED}UUID、serverName、publicKey、shortId 均为必填${NC}"
                return 1
            fi
            jq -n \
                --arg tag "$tag" \
                --arg address "$address" \
                --arg port "$port" \
                --arg uuid "$uuid" \
                --arg serverName "$serverName" \
                --arg publicKey "$publicKey" \
                --arg shortId "$shortId" \
                '{
                    tag: $tag,
                    protocol: "vless",
                    settings: {
                        vnext: [{
                            address: $address,
                            port: ($port | tonumber),
                            users: [{id: $uuid, flow: "xtls-rprx-vision", encryption: "none"}]
                        }]
                    },
                    streamSettings: {
                        network: "tcp",
                        security: "reality",
                        realitySettings: {
                            serverName: $serverName,
                            fingerprint: "chrome",
                            publicKey: $publicKey,
                            shortId: $shortId
                        }
                    }
                }' > "$out_file"
            ;;
        2)  # SOCKS5
            if [[ -z "$address" || -z "$port" ]]; then
                echo -e "${RED}地址和端口不能为空${NC}"
                return 1
            fi
            local use_auth=$(get_or_ask "SOCKS_AUTH" "启用用户名密码认证? (y/N)" "n")
            local socks_user="" socks_pass=""
            if [[ "$use_auth" =~ ^[Yy]$ ]]; then
                socks_user=$(get_or_ask "SOCKS_USER" "用户名" "")
                socks_pass=$(get_or_ask "SOCKS_PASS" "密码" "")
                if [[ -z "$socks_user" || -z "$socks_pass" ]]; then
                    echo -e "${RED}用户名和密码不能为空${NC}"
                    return 1
                fi
            fi
            jq -n \
                --arg tag "$tag" \
                --arg address "$address" \
                --arg port "$port" \
                --arg user "$socks_user" \
                --arg pass "$socks_pass" \
                '{
                    tag: $tag,
                    protocol: "socks",
                    settings: {
                        servers: [{
                            address: $address,
                            port: ($port | tonumber)
                        } + (if ($user != "" and $pass != "") then {users: [{user: $user, pass: $pass}]} else {} end)]
                    }
                }' > "$out_file"
            ;;
        3)  # WireGuard (WARP)
            local wg_private=$(get_or_ask "WG_PRIVATE_KEY" "WG 私钥" "")
            if [[ -z "$wg_private" ]]; then
                echo -e "${RED}私钥不能为空${NC}"
                return 1
            fi
            local wg_address=$(get_or_ask "WG_ADDRESS" "WG 地址" "172.16.0.2/32")
            local wg_endpoint=$(get_or_ask "WG_ENDPOINT" "WG 端点" "engage.cloudflareclient.com:2408")
            local wg_public=$(get_or_ask "WG_PUBLIC_KEY" "WG 公钥" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
            local wg_reserved=$(get_or_ask "WG_RESERVED" "WG Reserved (0,0,0)" "")
            local wg_domain_strategy=$(get_or_ask "WG_DOMAIN_STRATEGY" "domainStrategy" "ForceIPv4")
            IFS=',' read -ra ADDRS <<< "$wg_address"
            local address_array="[]"
            for a in "${ADDRS[@]}"; do
                a=$(echo "$a" | xargs)
                [[ -n "$a" ]] && address_array=$(echo "$address_array" | jq --arg a "$a" '. += [$a]')
            done
            local reserved_json="null"
            [[ -n "$wg_reserved" ]] && reserved_json="[$wg_reserved]"
            jq -n \
                --arg tag "$tag" \
                --arg privateKey "$wg_private" \
                --argjson address "$address_array" \
                --arg endpoint "$wg_endpoint" \
                --arg publicKey "$wg_public" \
                --argjson reserved "$reserved_json" \
                --arg domainStrategy "$wg_domain_strategy" \
                '{
                    tag: $tag,
                    protocol: "wireguard",
                    settings: {
                        secretKey: $privateKey,
                        address: $address,
                        peers: [{endpoint: $endpoint, publicKey: $publicKey}],
                        reserved: $reserved,
                        domainStrategy: $domainStrategy
                    }
                }' > "$out_file"
            ;;
        *)
            echo -e "${RED}未知出站类型${NC}"
            return 1
            ;;
    esac
    echo -e "${GREEN}出站已添加: $tag${NC}"
}

add_route() {
    echo -e "${BLUE}添加路由规则${NC}"
    local name=$(get_or_ask "ROUTE_NAME" "规则名称" "")
    if [[ -z "$name" ]]; then
        echo -e "${RED}名称不能为空${NC}"
        return 1
    fi
    local outbound=$(get_or_ask "ROUTE_OUTBOUND" "目标出站标签" "")
    if [[ -z "$outbound" ]]; then
        echo -e "${RED}目标出站标签不能为空${NC}"
        return 1
    fi
    local domain=$(get_or_ask "ROUTE_DOMAIN" "域名匹配" "")
    local ip=$(get_or_ask "ROUTE_IP" "IP匹配" "")
    local port=$(get_or_ask "ROUTE_PORT" "端口匹配" "")
    local network=$(get_or_ask "ROUTE_NETWORK" "网络类型" "")
    local rule_json="{\"type\":\"field\",\"outboundTag\":\"$outbound\""
    [[ -n "$domain" ]] && rule_json="$rule_json,\"domain\":[$(echo "$domain" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
    [[ -n "$ip" ]] && rule_json="$rule_json,\"ip\":[$(echo "$ip" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
    [[ -n "$port" ]] && rule_json="$rule_json,\"localPort\":\"$port\""
    [[ -n "$network" ]] && rule_json="$rule_json,\"network\":\"$network\""
    rule_json="$rule_json}"
    echo "$rule_json" > "$ROUTES_DIR/${name}.json"
    echo -e "${GREEN}路由规则已保存: $name${NC}"
}

generate_share_links() {
    echo -e "${BLUE}分享链接${NC}"
    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray 未安装${NC}"
        return 1
    fi
    if [[ ! -d "$INBOUNDS_DIR" || -z "$(ls -A "$INBOUNDS_DIR" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}没有入站配置${NC}"
        return 1
    fi
    local public_ip=$(curl -s4m5 https://icanhazip.com 2>/dev/null || curl -s6m5 https://icanhazip.com 2>/dev/null)
    [[ -z "$public_ip" ]] && public_ip=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
    [[ -z "$public_ip" ]] && public_ip="<YOUR_IP>"
    local public_key=$(cat "$REALITY_KEY_DIR/public_key" 2>/dev/null)
    for f in "$INBOUNDS_DIR"/*.json; do
        local tag=$(jq -r '.tag' "$f" 2>/dev/null)
        local port=$(jq -r '.port' "$f" 2>/dev/null)
        local uuid=$(jq -r '.settings.clients[0].id' "$f" 2>/dev/null)
        local flow=$(jq -r '.settings.clients[0].flow' "$f" 2>/dev/null)
        local decryption=$(jq -r '.settings.decryption' "$f" 2>/dev/null)
        local streamSettings=$(jq -r '.streamSettings' "$f" 2>/dev/null)
        local network=$(echo "$streamSettings" | jq -r '.network' 2>/dev/null)
        local security=$(echo "$streamSettings" | jq -r '.security' 2>/dev/null)
        local realitySettings=$(echo "$streamSettings" | jq -r '.realitySettings' 2>/dev/null)
        local tlsSettings=$(echo "$streamSettings" | jq -r '.tlsSettings' 2>/dev/null)
        local xhttpSettings=$(echo "$streamSettings" | jq -r '.xhttpSettings' 2>/dev/null)
        local base="vless://${uuid}@${public_ip}:${port}"
        local params=""
        if [ "$security" = "reality" ]; then
            local dest=$(echo "$realitySettings" | jq -r '.dest' 2>/dev/null | cut -d':' -f1)
            local serverNames=$(echo "$realitySettings" | jq -r '.serverNames[0]' 2>/dev/null)
            local shortId=$(echo "$realitySettings" | jq -r '.shortIds[0]' 2>/dev/null)
            local sni="${serverNames:-$dest}"
            params="encryption=none&security=reality&sni=${sni}&fp=chrome&type=${network:-tcp}&flow=${flow:-xtls-rprx-vision}&pbk=${public_key}&sid=${shortId}"
        else
            local enc="none"
            if [ "$decryption" != "none" ] && [ "$decryption" != "null" ] && [ -n "$decryption" ]; then
                [[ -f "$ENC_DIR/inbound-${port}.enc" ]] && enc=$(cat "$ENC_DIR/inbound-${port}.enc") || enc="none"
            fi
            local security_param="none"
            local sni_param=""
            local path_param=""
            if [ "$security" = "tls" ]; then
                security_param="tls"
                sni_param=$(echo "$tlsSettings" | jq -r '.serverName' 2>/dev/null)
                [[ -z "$sni_param" || "$sni_param" = "null" ]] && sni_param=""
            fi
            if [ "$network" = "xhttp" ]; then
                path_param=$(echo "$xhttpSettings" | jq -r '.path' 2>/dev/null)
                [[ -z "$path_param" || "$path_param" = "null" ]] && path_param=""
                [ "$path_param" = "/" ] && path_param=""
            fi
            params="encryption=${enc}&security=${security_param}&type=${network:-tcp}"
            [[ -n "$sni_param" ]] && params="${params}&sni=${sni_param}"
            [[ -n "$path_param" ]] && params="${params}&path=${path_param}"
        fi
        echo -e "${GREEN}${base}?${params}#${tag}${NC}"
    done
}

install_xray() {
    echo -e "${BLUE}安装 Xray${NC}"
    mkdir -p "$XR_DIR" "$CONFIG_DIR" "$LOG_DIR" "$INBOUNDS_DIR" "$OUTBOUNDS_DIR" "$ROUTES_DIR" "$CERTS_DIR" "$ENC_DIR"
    install_deps
    local arch=$(get_arch)
    if [[ "$arch" = "unsupported" ]]; then
        echo -e "${RED}不支持的架构${NC}"
        return 1
    fi
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    echo -e "${CYAN}下载 $url${NC}"
    local zip_file="/tmp/xray-${arch}.zip"
    curl -L -o "$zip_file" "$url" || wget -O "$zip_file" "$url"
    if [[ ! -f "$zip_file" ]]; then
        echo -e "${RED}下载失败${NC}"
        return 1
    fi
    unzip -o "$zip_file" -d "$XR_DIR" >/dev/null 2>&1
    rm -f "$zip_file"
    chmod +x "$XRAY_BIN"
    if [[ -f "$XRAY_BIN" ]]; then
        echo -e "${GREEN}Xray 安装成功: $($XRAY_BIN version | head -1)${NC}"
    else
        echo -e "${RED}安装失败${NC}"
        return 1
    fi
}

update_xray() {
    echo -e "${BLUE}更新 Xray${NC}"
    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray 未安装${NC}"
        return 1
    fi
    mv "$XRAY_BIN" "$XRAY_BIN.bak"
    if install_xray; then
        rm -f "$XRAY_BIN.bak"
    else
        mv "$XRAY_BIN.bak" "$XRAY_BIN"
        echo -e "${RED}更新失败${NC}"
        return 1
    fi
}

uninstall_xray() {
    echo -e "${RED}卸载 Xray${NC}"
    local confirm=$(get_or_ask "UNINSTALL_CONFIRM" "确认卸载? (y/N)" "n")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}取消${NC}"
        return
    fi
    service_control stop >/dev/null 2>&1
    pkill -f "xray run" 2>/dev/null
    rm -rf "$XR_DIR"
    rm -f /etc/systemd/system/xray.service /etc/init.d/xray
    systemctl daemon-reload 2>/dev/null
    echo -e "${GREEN}已卸载${NC}"
}

list_all() {
    if [[ -f "$XRAY_JSON" ]]; then
        cat "$XRAY_JSON"
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi
}

delete_menu() {
    echo "  1) 删除入站"
    echo "  2) 删除出站"
    echo "  3) 删除路由"
    read -p "选择: " d
    case $d in
        1)
            local name=$(get_or_ask "DELETE_INBOUND" "入站名称" "")
            [[ -n "$name" ]] && rm -f "$INBOUNDS_DIR/${name}.json" "$ENC_DIR/${name}.enc" && echo -e "${GREEN}已删除${NC}"
            ;;
        2)
            local name=$(get_or_ask "DELETE_OUTBOUND" "出站名称" "")
            [[ -n "$name" ]] && rm -f "$OUTBOUNDS_DIR/${name}.json" && echo -e "${GREEN}已删除${NC}"
            ;;
        3)
            local name=$(get_or_ask "DELETE_ROUTE" "路由名称" "")
            [[ -n "$name" ]] && rm -f "$ROUTES_DIR/${name}.json" && echo -e "${GREEN}已删除${NC}"
            ;;
    esac
}

show_menu() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}           Xray 管理脚本${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "  1) 安装 Xray"
    echo "  2) 更新 Xray"
    echo "  3) 卸载 Xray"
    echo "  4) 添加入站"
    echo "  5) 添加出站"
    echo "  6) 添加路由"
    echo "  7) 列出所有配置"
    echo "  8) 删除 (入站/出站/路由)"
    echo "  9) 生成配置"
    echo " 10) 启动 Xray"
    echo " 11) 停止 Xray"
    echo " 12) 重启 Xray"
    echo " 13) 生成分享链接"
    echo " 14) 查看状态"
    echo "  0) 退出"
    echo -e "${CYAN}========================================${NC}"
}

main() {
    if [[ -n "$ACTION" ]]; then
        case "$ACTION" in
            install)      install_xray ;;
            update)       update_xray ;;
            uninstall)    uninstall_xray ;;
            add_inbound)  add_inbound ;;
            add_outbound) add_outbound ;;
            add_route)    add_route ;;
            *)
                echo -e "${RED}当前仅支持: install, update, uninstall, add_inbound, add_outbound, add_route${NC}"
                exit 1
                ;;
        esac

        if [[ "$ACTION" =~ ^(add_inbound|add_outbound|add_route)$ ]]; then
            generate_config
            service_control restart
        fi

        exit 0
    fi

    while true; do
        show_menu
        read -p "选择 [0-14]: " choice
        case $choice in
            1)  install_xray ;;
            2)  update_xray ;;
            3)  uninstall_xray ;;
            4)  add_inbound ;;
            5)  add_outbound ;;
            6)  add_route ;;
            7)  list_all ;;
            8)  delete_menu ;;
            9)  generate_config ;;
            10) service_control start ;;
            11) service_control stop ;;
            12) service_control restart ;;
            13) generate_share_links ;;
            14) service_control status ;;
            0)  echo -e "${GREEN}再见${NC}"; exit 0 ;;
            *)  echo -e "${RED}无效选择${NC}" ;;
        esac
        echo ""
        read -p "按回车继续..."
    done
}

main "$@"