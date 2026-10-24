#!/bin/sh

AUTH_SERVER="http://10.80.80.249"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

STATE_DIR="/var/log/zjkju-auth"
CACHE_FILE="$STATE_DIR/last-url"
ONLINE_FLAG="$STATE_DIR/online-printed"
STATUS_FILE="$STATE_DIR/status"

mkdir -p "$STATE_DIR"

# 冷却变量
FAIL_COUNT=0
MAX_FAIL=3
FAIL_COOLDOWN_SEC=300

PENDING_COUNT=0
MAX_PENDING=3
PENDING_COOLDOWN_INIT=300
PENDING_COOLDOWN_CURRENT=300

TIMEOUT_COUNT=0
MAX_TIMEOUT=3
TIMEOUT_COOLDOWN_INIT=300
TIMEOUT_COOLDOWN_CURRENT=300
MAX_COOLDOWN=1800

COOLDOWN_CHECK_INTERVAL=10
NOCONFIG_LOGGED=0

. /lib/functions.sh

log_msg() {
    logger -t zjkju-auth "$1"
}

# 【修改】静默退出，不写日志
trap 'exit 0' TERM INT

set_status() { echo "$1" > "$STATUS_FILE"; }
log_msg "wrapper started"

# ==========================================
# 智能对时函数（仅在时钟异常且网络已通时执行）
# ==========================================
clock_is_bad() {
    local y
    y=$(date +%Y 2>/dev/null)
    [ -n "$y" ] && [ "$y" -lt 2024 ] 2>/dev/null
}

do_ntp_sync() {
    log_msg "系统时钟异常（$(date +%Y 2>/dev/null)），尝试对时"

    if command -v ntpd >/dev/null 2>&1; then
        ntpd -n -q -p ntp.aliyun.com -p ntp.tencent.com -p pool.ntp.org >/dev/null 2>&1 &
        NTP_PID=$!
        i=0
        while [ "$i" -lt 5 ]; do
            sleep 1
            clock_is_bad || break
            i=$((i + 1))
        done
        kill "$NTP_PID" 2>/dev/null
        wait "$NTP_PID" 2>/dev/null
    fi

    if clock_is_bad; then
        if [ -x /etc/init.d/sysntpd ]; then
            /etc/init.d/sysntpd restart >/dev/null 2>&1
            log_msg "未找到 ntpd 或对时未成功，已交给系统 sysntpd 继续尝试"
        else
            log_msg "对时未成功，继续运行（日志时间可能不准）"
        fi
    else
        log_msg "对时成功：$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

normalize_interval() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) echo 10; return ;; esac
    [ "$v" -lt 5 ] && { echo 10; return; }
    [ "$v" -gt 3600 ] && { echo 3600; return; }
    echo "$v"
}

is_online() {
    for PING_TARGET in 223.5.5.5 223.6.6.6; do
        if ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1; then return 0; fi
    done
    BODY=$(curl -s --max-time 5 -A "$UA" "http://www.msftconnecttest.com/connecttest.txt" 2>/dev/null | tr -d '\r\n')
    [ "$BODY" = "Microsoft Connect Test" ]
}

html_decode() {
    echo "$1" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

fetch_auth_url_auto() {
    for TRIGGER in "http://www.baidu.com/" "http://www.example.com/" "http://www.qualcomm.com/" "http://www.neverssl.com/" "http://www.qq.com/"; do
        RAW=$(curl -s -i --max-time 5 -A "$UA" "$TRIGGER" 2>/dev/null)
        LOC=$(echo "$RAW" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r\n')
        LOC=$(html_decode "$LOC")
        case "$LOC" in *wlanuserip=*) echo "$LOC"; return 0 ;; esac
        EXT=$(echo "$RAW" | grep -oE "http[s]?://[^\"'<> ]*wlanuserip=[^\"'<> ]*" | head -1)
        EXT=$(html_decode "$EXT")
        if [ -n "$EXT" ]; then echo "$EXT"; return 0; fi
        EXT=$(echo "$RAW" | grep -oE "/eportal/index\.jsp\?[^\"'<> ]+" | head -1)
        EXT=$(html_decode "$EXT")
        if [ -n "$EXT" ]; then echo "$AUTH_SERVER$EXT"; return 0; fi
    done
    return 1
}

fetch_auth_url_cache() {
    if [ -f "$CACHE_FILE" ]; then
        CACHED=$(cat "$CACHE_FILE" 2>/dev/null)
        if echo "$CACHED" | grep -q "wlanuserip="; then echo "$CACHED"; return 0; fi
    fi
    return 1
}

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

do_auth() {
    AUTH_URL="$1"; USERNAME="$2"; PASSWORD="$3"; SERVICE="$4"
    QUERY_STRING="${AUTH_URL#*\?}"
    if [ "$QUERY_STRING" = "$AUTH_URL" ]; then
        log_msg "URL 无效，跳过"
        return 2
    fi
    QS_ENCODED=$(urlencode_query "$QUERY_STRING")

    log_msg "锐捷认证客户端启动"
    log_msg "用户名: $USERNAME"
    log_msg "认证地址: $AUTH_URL"

    RESPONSE=$(curl -s --max-time 10 -X POST "$AUTH_SERVER/eportal/InterFace.do?method=login" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "User-Agent: $UA" -H "Referer: $AUTH_URL" -H "Origin: $AUTH_SERVER" \
        --data-urlencode "userId=$USERNAME" --data-urlencode "password=$PASSWORD" \
        --data-urlencode "service=$SERVICE" --data-urlencode "queryString=$QS_ENCODED" \
        --data-urlencode "operatorPwd=" --data-urlencode "operatorUserId=" \
        --data-urlencode "validcode=" --data-urlencode "passwordEncrypt=false" 2>&1)

    log_msg "响应内容: $(echo "$RESPONSE" | head -c 300)"

    case "$RESPONSE" in
        *'"result":"success"'*) log_msg "认证成功！"; return 0 ;;
        *'"result":"fail"'*)
            MSG=$(echo "$RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
            [ -z "$MSG" ] && MSG="未知错误"
            log_msg "认证失败: $MSG"
            return 1 ;;
        *) log_msg "认证请求已提交（响应无法识别）"; return 2 ;;
    esac
}

cooldown_wait() {
    local cur_user="$1"
    local cur_pass="$2"
    local wait_sec="$3"
    local deadline
    deadline=$(( $(date +%s) + wait_sec ))

    set_status "cooling"

    while :; do
        sleep "$COOLDOWN_CHECK_INTERVAL"
        if is_online; then set_status "online"; return 0; fi
        config_load zjkju-auth
        local new_user new_pass
        config_get new_user main username
        config_get new_pass main password
        if [ "$new_user" != "$cur_user" ] || [ "$new_pass" != "$cur_pass" ]; then
            set_status "offline"; return 0
        fi
        [ "$(date +%s)" -ge "$deadline" ] && break
    done
    set_status "offline"
    return 0
}

STATE="init"
EVER_ONLINE=0
NTP_TRIED=0

while true; do
    config_load zjkju-auth
    config_get_bool enabled main enabled 1
    config_get username main username
    config_get password main password
    config_get service main service
    config_get check_interval main check_interval 10
    check_interval=$(normalize_interval "$check_interval")

    if [ "$enabled" != "1" ]; then set_status "disabled"; sleep 10; continue; fi

    if [ -z "$username" ] || [ -z "$password" ]; then
        set_status "noconfig"
        if [ "$NOCONFIG_LOGGED" != "1" ]; then
            log_msg "未配置学号/密码，等待用户在 LuCI 界面填写"
            NOCONFIG_LOGGED=1
        fi
        sleep 5; continue
    fi
    NOCONFIG_LOGGED=0

    if [ -f "$CACHE_FILE" ]; then
        NOW=$(date +%s); FILE_TIME=$(date -r "$CACHE_FILE" +%s 2>/dev/null)
        if [ -n "$FILE_TIME" ] && [ "$FILE_TIME" -gt 0 ] 2>/dev/null; then
            AGE=$((NOW - FILE_TIME))
            if [ "$AGE" -gt 21600 ]; then
                rm -f "$CACHE_FILE"
            fi
        fi
    fi

    if is_online; then
        set_status "online"

        if [ "$NTP_TRIED" -lt 3 ] && clock_is_bad; then
            NTP_TRIED=$((NTP_TRIED + 1))
            do_ntp_sync
        fi

        if [ ! -f "$ONLINE_FLAG" ]; then
            case "$STATE" in
                init) log_msg "已联网，无需认证" ;;
                offline) [ "$EVER_ONLINE" = "1" ] && log_msg "网络已恢复" ;;
            esac
            touch "$ONLINE_FLAG"
        fi
        STATE="online"; EVER_ONLINE=1; FAIL_COUNT=0; PENDING_COUNT=0; TIMEOUT_COUNT=0
        TIMEOUT_COOLDOWN_CURRENT=$TIMEOUT_COOLDOWN_INIT
        PENDING_COOLDOWN_CURRENT=$PENDING_COOLDOWN_INIT
        sleep "$check_interval"; continue
    fi

    set_status "offline"
    rm -f "$ONLINE_FLAG"

    if [ "$STATE" = "online" ]; then
        sleep 10
        if is_online; then
            set_status "online"
            touch "$ONLINE_FLAG"
            STATE="online"
            sleep "$check_interval"; continue
        fi
    fi

    AUTH_URL=$(fetch_auth_url)
    if [ -z "$AUTH_URL" ]; then
        sleep 10; continue
    fi

    if [ "$STATE" != "offline" ]; then
        log_msg "检测到掉线，开始认证"
        STATE="offline"
    fi

    [ -z "$service" ] && service="%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91"
    do_auth "$AUTH_URL" "$username" "$password" "$service"
    RC=$?

    if [ "$RC" = "0" ]; then
        case "$AUTH_URL" in *wlanuserip=*) echo "$AUTH_URL" > "$CACHE_FILE" ;; esac
        FAIL_COUNT=0; TIMEOUT_COUNT=0
        PENDING_COUNT=$((PENDING_COUNT + 1))
        if [ "$PENDING_COUNT" -ge "$MAX_PENDING" ]; then
            cooldown_wait "$username" "$password" "$PENDING_COOLDOWN_CURRENT"
            PENDING_COOLDOWN_CURRENT=$((PENDING_COOLDOWN_CURRENT + 300))
            [ "$PENDING_COOLDOWN_CURRENT" -gt "$MAX_COOLDOWN" ] && PENDING_COOLDOWN_CURRENT=$MAX_COOLDOWN
            PENDING_COUNT=0; sleep "$check_interval"; continue
        fi
        RETRY_DELAY=$((15 * PENDING_COUNT)); [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120
    else
        PENDING_COUNT=0
        if [ "$RC" = "2" ] && [ -f "$CACHE_FILE" ]; then
            CACHED_URL=$(cat "$CACHE_FILE" 2>/dev/null)
            if [ "$CACHED_URL" = "$AUTH_URL" ]; then rm -f "$CACHE_FILE"; fi
        fi
        if [ "$RC" = "2" ]; then
            TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
            if [ "$TIMEOUT_COUNT" -ge "$MAX_TIMEOUT" ]; then
                cooldown_wait "$username" "$password" "$TIMEOUT_COOLDOWN_CURRENT"
                TIMEOUT_COOLDOWN_CURRENT=$((TIMEOUT_COOLDOWN_CURRENT + 300))
                [ "$TIMEOUT_COOLDOWN_CURRENT" -gt "$MAX_COOLDOWN" ] && TIMEOUT_COOLDOWN_CURRENT=$MAX_COOLDOWN
                TIMEOUT_COUNT=0; sleep "$check_interval"; continue
            fi
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [ "$FAIL_COUNT" -ge "$MAX_FAIL" ]; then
                log_msg "连续 ${FAIL_COUNT} 次认证未成功，冷却 ${FAIL_COOLDOWN_SEC} 秒，请检查学号/密码/服务类型"
                cooldown_wait "$username" "$password" "$FAIL_COOLDOWN_SEC"
                FAIL_COUNT=0; sleep "$check_interval"; continue
            fi
        fi
        RETRY_DELAY=$((check_interval * (FAIL_COUNT + TIMEOUT_COUNT)))
        [ "$RETRY_DELAY" -lt 10 ] && RETRY_DELAY=10
        [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120
    fi
    sleep "$RETRY_DELAY"
done
