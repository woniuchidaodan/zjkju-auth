#!/bin/sh

AUTH_SERVER="http://10.80.80.249"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
CACHE_FILE="/tmp/zjkju-auth-last-url"
ONLINE_FLAG="/tmp/zjkju-auth-online-printed"
STATUS_FILE="/tmp/zjkju-auth-status"
LOG_FILE="/var/log/zjkju-auth.log"
LOG_MAX_KB=256

# 失败熔断
FAIL_COUNT=0       # 认证明确失败（RC=1/2）
PENDING_COUNT=0    # 认证返回成功但探测仍离线（网关观察期）
MAX_FAIL=3
COOLDOWN_SEC=300
COOLDOWN_CHECK_INTERVAL=10

. /lib/functions.sh

log_msg() {
    if [ -f "$LOG_FILE" ]; then
        SIZE_KB=$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')
        if [ -n "$SIZE_KB" ] && [ "$SIZE_KB" -gt "$LOG_MAX_KB" ] 2>/dev/null; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
    logger -t zjkju-auth "$1"
}

set_status() {
    echo "$1" > "$STATUS_FILE"
}

log_msg "wrapper started"

# 规范化 check_interval
#   空 / 非数字 → 10
#   < 5        → 10
#   > 3600     → 3600
normalize_interval() {
    local v="$1"
    case "$v" in
        ''|*[!0-9]*) echo 10; return ;;
    esac
    [ "$v" -lt 5 ] && { echo 10; return; }
    [ "$v" -gt 3600 ] && { echo 3600; return; }
    echo "$v"
}

is_online() {
    for PING_TARGET in 223.5.5.5 223.6.6.6; do
        if ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1; then
            return 0
        fi
    done
    BODY=$(curl -s --max-time 5 -A "$UA" \
        "http://www.msftconnecttest.com/connecttest.txt" 2>/dev/null | tr -d '\r\n')
    [ "$BODY" = "Microsoft Connect Test" ]
}

html_decode() {
    echo "$1" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

fetch_auth_url_auto() {
    for TRIGGER in \
        "http://www.baidu.com/" \
        "http://www.example.com/" \
        "http://www.qualcomm.com/" \
        "http://www.neverssl.com/" \
        "http://www.qq.com/"; do

        RAW=$(curl -s -i --max-time 5 -A "$UA" "$TRIGGER" 2>/dev/null)

        LOC=$(echo "$RAW" | grep -i '^Location:' | head -1 \
            | sed 's/^[Ll]ocation: *//' | tr -d '\r\n')
        LOC=$(html_decode "$LOC")
        case "$LOC" in
            *wlanuserip=*) echo "$LOC"; return 0 ;;
        esac

        EXT=$(echo "$RAW" | grep -oE "http[s]?://[^\"'<> ]*wlanuserip=[^\"'<> ]*" | head -1)
        EXT=$(html_decode "$EXT")
        if [ -n "$EXT" ]; then
            echo "$EXT"
            return 0
        fi

        EXT=$(echo "$RAW" | grep -oE "/eportal/index\.jsp\?[^\"'<> ]+" | head -1)
        EXT=$(html_decode "$EXT")
        if [ -n "$EXT" ]; then
            echo "$AUTH_SERVER$EXT"
            return 0
        fi
    done

    return 1
}

fetch_auth_url_cache() {
    if [ -f "$CACHE_FILE" ]; then
        CACHED=$(cat "$CACHE_FILE" 2>/dev/null)
        if echo "$CACHED" | grep -q "wlanuserip="; then
            echo "$CACHED"
            return 0
        fi
    fi
    return 1
}

# 优先级：自动 → 缓存 → 手动兜底
# 项目设计前提是"不要固定 URL"，手动 URL 是最后的逃生口
fetch_auth_url() {
    URL=$(fetch_auth_url_auto)
    [ -n "$URL" ] && { echo "$URL"; return 0; }

    URL=$(fetch_auth_url_cache)
    [ -n "$URL" ] && { echo "$URL"; return 0; }

    config_get manual_url main manual_url
    [ -n "$manual_url" ] && { echo "$manual_url"; return 0; }

    return 1
}

urlencode_query() {
    echo "$1" | sed 's/=/\%3D/g; s/&/\%26/g'
}

# 返回值:
#   0 = 成功
#   1 = 业务失败（网关明确返回 fail）
#   2 = 无法判定（网络波动/响应异常）
do_auth() {
    AUTH_URL="$1"
    USERNAME="$2"
    PASSWORD="$3"
    SERVICE="$4"

    QUERY_STRING="${AUTH_URL#*\?}"
    if [ "$QUERY_STRING" = "$AUTH_URL" ]; then
        log_msg "URL 无效，跳过"
        return 2
    fi

    QS_ENCODED=$(urlencode_query "$QUERY_STRING")

    log_msg "正在尝试认证..."
    log_msg "锐捷认证客户端启动"
    log_msg "用户名: $USERNAME"
    log_msg "认证地址: $AUTH_URL"
    log_msg "提取到queryString (长度: ${#QUERY_STRING})"

    RESPONSE=$(curl -s --max-time 10 -X POST \
        "$AUTH_SERVER/eportal/InterFace.do?method=login" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "User-Agent: $UA" \
        -H "Referer: $AUTH_URL" \
        -H "Origin: $AUTH_SERVER" \
        --data-urlencode "userId=$USERNAME" \
        --data-urlencode "password=$PASSWORD" \
        --data-urlencode "service=$SERVICE" \
        --data-urlencode "queryString=$QS_ENCODED" \
        --data-urlencode "operatorPwd=" \
        --data-urlencode "operatorUserId=" \
        --data-urlencode "validcode=" \
        --data-urlencode "passwordEncrypt=false" \
        2>&1)

    log_msg "响应内容: $(echo "$RESPONSE" | head -c 300)"

    case "$RESPONSE" in
        *'"result":"success"'*)
            log_msg "认证成功！"
            return 0
            ;;
        *'"result":"fail"'*)
            MSG=$(echo "$RESPONSE" | grep -oE '"message":"[^"]+"' | head -1)
            log_msg "认证失败: $MSG"
            return 1
            ;;
        *)
            log_msg "认证请求已提交（响应无法识别）"
            return 2
            ;;
    esac
}

cooldown_wait() {
    local cur_user="$1"
    local cur_pass="$2"
    local waited=0

    while [ "$waited" -lt "$COOLDOWN_SEC" ]; do
        sleep "$COOLDOWN_CHECK_INTERVAL"
        waited=$((waited + COOLDOWN_CHECK_INTERVAL))

        config_load zjkju-auth
        local new_user
        local new_pass
        config_get new_user main username
        config_get new_pass main password

        if [ "$new_user" != "$cur_user" ] || [ "$new_pass" != "$cur_pass" ]; then
            log_msg "检测到账号/密码已修改，提前结束冷却，立即重新认证"
            return 0
        fi
    done

    log_msg "冷却结束，恢复认证尝试"
    return 0
}

# ============================================================
# 主循环
# ============================================================
STATE="init"
EVER_ONLINE=0

while true; do
    config_load zjkju-auth

    config_get_bool enabled main enabled 1
    config_get username main username
    config_get password main password
    config_get service main service
    config_get check_interval main check_interval 10

    check_interval=$(normalize_interval "$check_interval")

    if [ "$enabled" != "1" ]; then
        set_status "disabled"
        sleep 10
        continue
    fi

    if [ -z "$username" ] || [ -z "$password" ]; then
        set_status "noconfig"
        log_msg "未配置学号/密码，等待用户在 LuCI 界面填写"
        sleep 30
        continue
    fi

    # ============ 在线 ============
    if is_online; then
        set_status "online"
        if [ ! -f "$ONLINE_FLAG" ]; then
            case "$STATE" in
                init)
                    log_msg "已联网，无需认证"
                    ;;
                offline)
                    if [ "$EVER_ONLINE" = "1" ]; then
                        log_msg "网络已恢复"
                    fi
                    ;;
            esac
            touch "$ONLINE_FLAG"
        fi

        STATE="online"
        EVER_ONLINE=1
        FAIL_COUNT=0
        PENDING_COUNT=0
        sleep "$check_interval"
        continue
    fi

    # ============ 离线 ============
    set_status "offline"
    rm -f "$ONLINE_FLAG"

    AUTH_URL=$(fetch_auth_url)
    if [ -z "$AUTH_URL" ]; then
        sleep 5
        continue
    fi

    if [ "$STATE" != "offline" ]; then
        if [ "$EVER_ONLINE" = "1" ]; then
            log_msg "网络已断开，开始尝试重新认证"
        else
            log_msg "网络未连接，开始认证"
        fi
        STATE="offline"
    fi

    [ -z "$service" ] && service="%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91"

    do_auth "$AUTH_URL" "$username" "$password" "$service"
    RC=$?

    if [ "$RC" = "0" ]; then
        # 认证成功：缓存 URL
        case "$AUTH_URL" in
            *wlanuserip=*)
                echo "$AUTH_URL" > "$CACHE_FILE"
                ;;
        esac
        FAIL_COUNT=0

        # A4 真修：认证返回 success 但探测仍离线（网关观察期）
        # 用 PENDING_COUNT 计数，达到阈值也冷却
        PENDING_COUNT=$((PENDING_COUNT + 1))
        if [ "$PENDING_COUNT" -ge "$MAX_FAIL" ]; then
            log_msg "连续 ${PENDING_COUNT} 次认证返回成功但仍离线，冷却 ${COOLDOWN_SEC} 秒（可能是网关观察期）"
            cooldown_wait "$username" "$password"
            PENDING_COUNT=0
            sleep "$check_interval"
            continue
        fi

        # 指数退避：15 → 30 → 60 → 120（上限）
        RETRY_DELAY=$((15 * PENDING_COUNT))
        [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120

    else
        # RC=1（明确失败）和 RC=2（响应无法识别）都计入 FAIL_COUNT
        PENDING_COUNT=0
        FAIL_COUNT=$((FAIL_COUNT + 1))

        if [ "$FAIL_COUNT" -ge "$MAX_FAIL" ]; then
            log_msg "连续 ${FAIL_COUNT} 次认证未成功，冷却 ${COOLDOWN_SEC} 秒，请检查学号/密码/服务类型"
            cooldown_wait "$username" "$password"
            FAIL_COUNT=0
            sleep "$check_interval"
            continue
        fi

        RETRY_DELAY=$((check_interval * FAIL_COUNT))
        [ "$RETRY_DELAY" -lt 10 ] && RETRY_DELAY=10
        [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120
    fi

    sleep "$RETRY_DELAY"
done
