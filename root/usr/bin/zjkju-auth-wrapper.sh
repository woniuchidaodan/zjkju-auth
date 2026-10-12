#!/bin/sh

AUTH_SERVER="http://10.80.80.249"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
CACHE_FILE="/tmp/zjkju-auth-last-url"
ONLINE_FLAG="/tmp/zjkju-auth-online-printed"
LOG_FILE="/var/log/zjkju-auth.log"
LOG_MAX_KB=256

# 失败熔断
FAIL_COUNT=0
MAX_FAIL=3
COOLDOWN_SEC=300

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

log_msg "wrapper started"

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

fetch_auth_url() {
    config_get manual_url main manual_url
    if [ -n "$manual_url" ]; then
        echo "$manual_url"
        return 0
    fi

    # 触发网关 302 的探测地址（不含 example.com，避免语义不当）
    for TRIGGER in \
        "http://www.baidu.com/" \
        "http://www.qualcomm.com/" \
        "http://www.neverssl.com/" \
        "http://www.qq.com/"; do

        RAW=$(curl -s -i --max-time 5 -A "$UA" "$TRIGGER" 2>/dev/null)

        LOC=$(echo "$RAW" | grep -i '^Location:' | head -1 \
            | sed 's/^[Ll]ocation: *//' | tr -d '\r\n')
        case "$LOC" in
            *wlanuserip=*) echo "$LOC"; return 0 ;;
        esac

        EXT=$(echo "$RAW" | grep -oE "http[s]?://[^\"'<> ]*wlanuserip=[^\"'<> ]*" | head -1)
        if [ -n "$EXT" ]; then
            echo "$EXT"
            return 0
        fi

        EXT=$(echo "$RAW" | grep -oE "/eportal/index\.jsp\?[^\"'<> ]+" | head -1)
        if [ -n "$EXT" ]; then
            echo "$AUTH_SERVER$EXT"
            return 0
        fi
    done

    if [ -f "$CACHE_FILE" ]; then
        CACHED=$(cat "$CACHE_FILE" 2>/dev/null)
        if echo "$CACHED" | grep -q "wlanuserip="; then
            echo "$CACHED"
            return 0
        fi
    fi

    return 1
}

urlencode_query() {
    echo "$1" | sed 's/=/\%3D/g; s/&/\%26/g'
}

# 返回值:
#   0 = 成功
#   1 = 业务失败（认证被拒，计入熔断）
#   2 = 无法判定（网络波动/响应异常，不计入熔断）
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

    if [ "$enabled" != "1" ]; then
        sleep 10
        continue
    fi

    if [ -z "$username" ] || [ -z "$password" ]; then
        log_msg "未配置学号/密码，等待用户在 LuCI 界面填写"
        sleep 30
        continue
    fi

    # ============ 在线 ============
    if is_online; then
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
        sleep "$check_interval"
        continue
    fi

    # ============ 离线 ============
    rm -f "$ONLINE_FLAG"

    AUTH_URL=$(fetch_auth_url)
    if [ -z "$AUTH_URL" ]; then
        # 拿不到 URL：网络波动，不计入熔断
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
        case "$AUTH_URL" in
            *wlanuserip=*)
                echo "$AUTH_URL" > "$CACHE_FILE"
                ;;
        esac
        FAIL_COUNT=0
    elif [ "$RC" = "1" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        if [ "$FAIL_COUNT" -ge "$MAX_FAIL" ]; then
            log_msg "连续 ${FAIL_COUNT} 次认证失败，冷却 ${COOLDOWN_SEC} 秒，请检查学号/密码/服务类型"
            sleep "$COOLDOWN_SEC"
            FAIL_COUNT=0
        fi
    fi
    # RC=2（URL 无效 / 响应无法识别）不计入熔断

    sleep "$check_interval"
done
