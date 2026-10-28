#!/bin/sh

AUTH_SERVER="http://10.80.80.249"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

STATE_DIR="/var/log/zjkju-auth"
LOG_FILE="$STATE_DIR/auth.log"
CACHE_FILE="$STATE_DIR/last-url"
ONLINE_FLAG="$STATE_DIR/online-printed"
STATUS_FILE="$STATE_DIR/status"
CLOCK_STAMP="$STATE_DIR/clock-ok"

mkdir -p "$STATE_DIR"

LOG_MAX_LINES=2000
LOG_KEEP_LINES=1500
LOG_COUNT=0

BUFFERED_LOG=""
BUFFERED_LINE_COUNT=0
BUFFERED_MAX=200

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
AUTHURL_MISS_LOGGED=0
AUTH_STARTED=0

NTP_LAN_SERVER=""
CLOCK_SYNCED=0
LAST_NTP_ATTEMPT=0

. /lib/functions.sh

if [ -f "$CLOCK_STAMP" ]; then
    _y=$(date +%Y 2>/dev/null)
    if [ -n "$_y" ] && [ "$_y" -ge 2024 ] 2>/dev/null; then
        CLOCK_SYNCED=1
    fi
fi

_log_rotate_check() {
    LOG_COUNT=$((LOG_COUNT + 1))
    [ "$LOG_COUNT" -lt 200 ] && return
    LOG_COUNT=0
    local cur
    cur=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$cur" -gt "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

_force_flush_buffer() {
    [ -z "$BUFFERED_LOG" ] && { BUFFERED_LINE_COUNT=0; return; }
    local ts tmp
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    tmp="$STATE_DIR/.buf.tmp"
    printf '%s' "$BUFFERED_LOG" > "$tmp"
    while IFS='|' read -r _e m; do
        [ -z "$m" ] && continue
        printf '%s %s\n' "$ts" "$m" >> "$LOG_FILE"
    done < "$tmp"
    rm -f "$tmp"
    BUFFERED_LOG=""
    BUFFERED_LINE_COUNT=0
    _log_rotate_check
}

_flush_buffer_with_offset() {
    [ -z "$BUFFERED_LOG" ] && { BUFFERED_LINE_COUNT=0; return; }
    local offset="$1" tmp fixed ts
    tmp="$STATE_DIR/.buf.tmp"
    printf '%s' "$BUFFERED_LOG" > "$tmp"
    while IFS='|' read -r e m; do
        [ -z "$m" ] && continue
        [ -z "$e" ] && e=0
        fixed=$((e + offset))
        ts=$(date -D %s -d "$fixed" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        [ -z "$ts" ] && ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        printf '%s %s\n' "$ts" "$m" >> "$LOG_FILE"
    done < "$tmp"
    rm -f "$tmp"
    BUFFERED_LOG=""
    BUFFERED_LINE_COUNT=0
    _log_rotate_check
}

log_msg() {
    local msg="$1" ts e
    msg=$(printf '%s' "$msg" | tr '\n\r\t' '   ')
    logger -t zjkju-auth "$msg"

    if [ "$CLOCK_SYNCED" = "1" ]; then
        ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILE"
        _log_rotate_check
    else
        e=$(date +%s 2>/dev/null)
        [ -z "$e" ] && e=0
        BUFFERED_LOG="${BUFFERED_LOG}${e}|${msg}
"
        BUFFERED_LINE_COUNT=$((BUFFERED_LINE_COUNT + 1))
        [ "$BUFFERED_LINE_COUNT" -ge "$BUFFERED_MAX" ] && _force_flush_buffer
    fi
}

trap '_force_flush_buffer; exit 0' TERM INT

set_status() { echo "$1" > "$STATUS_FILE"; }

# 可被 TERM 打断的分段睡眠：保证收到停止信号后 1 秒内退出，
# 而不是等当前 sleep（最长 120 秒）跑完才执行 trap。
sleep_i() {
    local _n="$1"
    case "$_n" in ''|*[!0-9]*) _n=1 ;; esac
    while [ "$_n" -gt 0 ]; do
        sleep 1
        _n=$((_n - 1))
    done
}

do_ntp_sync() {
    local prev now delta i rc stepped ntpd_done

    [ "$CLOCK_SYNCED" = "1" ] && return 0
    stepped=0; ntpd_done=0; rc=1

    if command -v ntpd >/dev/null 2>&1; then
        if [ -n "$NTP_LAN_SERVER" ]; then
            ntpd -n -q -p "$NTP_LAN_SERVER" -p ntp.aliyun.com -p ntp.tencent.com -p pool.ntp.org >/dev/null 2>&1 &
        else
            ntpd -n -q -p ntp.aliyun.com -p ntp.tencent.com -p pool.ntp.org >/dev/null 2>&1 &
        fi
        NTP_PID=$!

        prev=$(date +%s 2>/dev/null)
        i=0
        while [ "$i" -lt 4 ]; do
            if ! kill -0 "$NTP_PID" 2>/dev/null; then ntpd_done=1; break; fi
            sleep 1
            now=$(date +%s 2>/dev/null)
            delta=$((now - prev))
            { [ "$delta" -gt 5 ] || [ "$delta" -lt -5 ]; } && stepped=1
            prev=$now
            i=$((i + 1))
        done

        if [ "$ntpd_done" = "1" ]; then
            wait "$NTP_PID" 2>/dev/null; rc=$?
        else
            # 不能无界等待：ntpd 未必响应 SIGTERM，卡住会把整个主循环拖死
            kill "$NTP_PID" 2>/dev/null
            i=0
            while kill -0 "$NTP_PID" 2>/dev/null && [ "$i" -lt 3 ]; do
                i=$((i + 1))
                sleep 1
            done
            kill -9 "$NTP_PID" 2>/dev/null
            rc=1
        fi

        if [ "$stepped" = "1" ] || [ "$rc" = "0" ]; then CLOCK_SYNCED=1; fi
    fi

    if [ "$CLOCK_SYNCED" != "1" ] && [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd restart >/dev/null 2>&1
    fi

    if [ "$CLOCK_SYNCED" = "1" ]; then
        touch "$CLOCK_STAMP" 2>/dev/null
        return 0
    fi
    return 1
}

do_ntp_sync_with_flush() {
    [ "$CLOCK_SYNCED" = "1" ] && return 0
    local T_before T_after offset rc
    T_before=$(date +%s 2>/dev/null); [ -z "$T_before" ] && T_before=0
    do_ntp_sync; rc=$?
    if [ "$CLOCK_SYNCED" = "1" ]; then
        T_after=$(date +%s 2>/dev/null); [ -z "$T_after" ] && T_after=$T_before
        offset=$((T_after - T_before))
        [ -n "$BUFFERED_LOG" ] && _flush_buffer_with_offset "$offset"
    fi
    return $rc
}

# 启动不再阻塞对时：主循环里的 try_ntp 会完成同步并按 offset 回填日志时间
log_msg "wrapper started"

normalize_interval() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) echo 10; return ;; esac
    [ "$v" -lt 5 ] && { echo 10; return; }
    [ "$v" -gt 3600 ] && { echo 3600; return; }
    echo "$v"
}

is_online() {
    for PING_TARGET in 223.5.5.5 223.6.6.6; do
        ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1 && return 0
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
        [ -n "$EXT" ] && { echo "$EXT"; return 0; }
        EXT=$(echo "$RAW" | grep -oE "/eportal/index\.jsp\?[^\"'<> ]+" | head -1)
        EXT=$(html_decode "$EXT")
        [ -n "$EXT" ] && { echo "$AUTH_SERVER$EXT"; return 0; }
    done
    return 1
}

fetch_auth_url_cache() {
    if [ -f "$CACHE_FILE" ]; then
        CACHED=$(cat "$CACHE_FILE" 2>/dev/null)
        echo "$CACHED" | grep -q "wlanuserip=" && { echo "$CACHED"; return 0; }
    fi
    return 1
}

fetch_auth_url() {
    URL=$(fetch_auth_url_auto); [ -n "$URL" ] && { echo "$URL"; return 0; }
    URL=$(fetch_auth_url_cache); [ -n "$URL" ] && { echo "$URL"; return 0; }
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

    TARGET_URL="$AUTH_SERVER/eportal/InterFace.do?method=login"

    if [ "$AUTH_STARTED" != "1" ]; then
        log_msg "锐捷认证客户端启动"
        AUTH_STARTED=1
    fi
    log_msg "正在尝试认证..."
    log_msg "认证请求URL: $TARGET_URL"
    log_msg "用户名: $USERNAME"
    log_msg "认证地址: $AUTH_URL"

    TMP_BODY="$STATE_DIR/.resp.$$"
    HTTP_CODE=$(curl -s -o "$TMP_BODY" -w "%{http_code}" --max-time 10 -X POST "$TARGET_URL" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "User-Agent: $UA" -H "Referer: $AUTH_URL" -H "Origin: $AUTH_SERVER" \
        --data-urlencode "userId=$USERNAME" --data-urlencode "password=$PASSWORD" \
        --data-urlencode "service=$SERVICE" --data-urlencode "queryString=$QS_ENCODED" \
        --data-urlencode "operatorPwd=" --data-urlencode "operatorUserId=" \
        --data-urlencode "validcode=" --data-urlencode "passwordEncrypt=false" 2>/dev/null)
    RESPONSE=$(cat "$TMP_BODY" 2>/dev/null)
    rm -f "$TMP_BODY"

    if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
        log_msg "认证请求失败: 网络错误或超时"
        return 2
    fi

    log_msg "响应状态: $HTTP_CODE"
    [ -n "$RESPONSE" ] && log_msg "响应内容: $(printf '%s' "$RESPONSE" | head -c 300)"

    if [ "$HTTP_CODE" = "200" ]; then
        case "$RESPONSE" in
            *'"result":"success"'*|*'登录成功'*|*'认证成功'*)
                log_msg "认证成功！"; return 0 ;;
            *'"result":"fail"'*|*'失败'*)
                MSG=$(echo "$RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
                [ -z "$MSG" ] && MSG="未知错误"
                log_msg "认证失败: $MSG"; return 1 ;;
            *'上网'*|*'已登录'*)
                log_msg "认证成功！"; return 0 ;;
            *)
                log_msg "认证请求已提交（响应无法识别）"; return 2 ;;
        esac
    fi
    log_msg "认证请求失败 (HTTP $HTTP_CODE)"
    return 2
}

cooldown_wait() {
    local cur_user="$1" cur_pass="$2" wait_sec="$3" deadline
    _force_flush_buffer
    deadline=$(( $(date +%s) + wait_sec ))
    set_status "cooling"
    while :; do
        sleep_i "$COOLDOWN_CHECK_INTERVAL"
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

try_ntp() {
    [ "$CLOCK_SYNCED" = "1" ] && return 0
    local now
    now=$(date +%s 2>/dev/null); [ -z "$now" ] && now=0
    if [ "$LAST_NTP_ATTEMPT" -gt 0 ] && [ $((now - LAST_NTP_ATTEMPT)) -lt 600 ]; then
        return 0
    fi
    LAST_NTP_ATTEMPT=$now
    do_ntp_sync_with_flush
}

STATE="init"

while true; do
    config_load zjkju-auth
    config_get_bool enabled main enabled 1
    config_get username main username
    config_get password main password
    config_get service main service
    config_get check_interval main check_interval 10
    check_interval=$(normalize_interval "$check_interval")

    if [ "$enabled" != "1" ]; then set_status "disabled"; sleep_i 10; continue; fi

    if [ -z "$username" ] || [ -z "$password" ]; then
        set_status "noconfig"
        if [ "$NOCONFIG_LOGGED" != "1" ]; then
            log_msg "未配置学号/密码，等待用户在 LuCI 界面填写"
            NOCONFIG_LOGGED=1
            _force_flush_buffer
        fi
        sleep_i 5; continue
    fi
    NOCONFIG_LOGGED=0

    if [ -f "$CACHE_FILE" ]; then
        NOW=$(date +%s); FILE_TIME=$(date -r "$CACHE_FILE" +%s 2>/dev/null)
        if [ -n "$FILE_TIME" ] && [ "$FILE_TIME" -gt 0 ] 2>/dev/null; then
            AGE=$((NOW - FILE_TIME))
            [ "$AGE" -gt 21600 ] && rm -f "$CACHE_FILE"
        fi
    fi

    if is_online; then
        set_status "online"
        try_ntp

        if [ ! -f "$ONLINE_FLAG" ]; then
            case "$STATE" in
                init)    log_msg "已联网，无需认证" ;;
                offline) log_msg "网络已恢复" ;;
            esac
            touch "$ONLINE_FLAG"
        fi

        [ "$CLOCK_SYNCED" != "1" ] && _force_flush_buffer

        STATE="online"; FAIL_COUNT=0; PENDING_COUNT=0; TIMEOUT_COUNT=0
        TIMEOUT_COOLDOWN_CURRENT=$TIMEOUT_COOLDOWN_INIT
        PENDING_COOLDOWN_CURRENT=$PENDING_COOLDOWN_INIT
        sleep_i "$check_interval"; continue
    fi

    set_status "offline"
    rm -f "$ONLINE_FLAG"

    if [ "$STATE" = "online" ]; then
        sleep_i 10
        if is_online; then
            set_status "online"; touch "$ONLINE_FLAG"; STATE="online"
            sleep_i "$check_interval"; continue
        fi
    fi

    AUTH_URL=$(fetch_auth_url)
    if [ -z "$AUTH_URL" ]; then
        if [ "$AUTHURL_MISS_LOGGED" != "1" ]; then
            log_msg "自动获取认证地址失败"
            AUTHURL_MISS_LOGGED=1
            _force_flush_buffer
        fi
        sleep_i 10; continue
    fi
    AUTHURL_MISS_LOGGED=0

    if [ "$STATE" != "offline" ]; then
        if [ "$STATE" = "online" ]; then
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
        case "$AUTH_URL" in *wlanuserip=*) echo "$AUTH_URL" > "$CACHE_FILE" ;; esac
        FAIL_COUNT=0; TIMEOUT_COUNT=0
        PENDING_COUNT=$((PENDING_COUNT + 1))
        if [ "$PENDING_COUNT" -ge "$MAX_PENDING" ]; then
            log_msg "连续 ${PENDING_COUNT} 次认证返回成功但仍离线，冷却 ${PENDING_COOLDOWN_CURRENT} 秒（可能是网关观察期）"
            cooldown_wait "$username" "$password" "$PENDING_COOLDOWN_CURRENT"
            PENDING_COOLDOWN_CURRENT=$((PENDING_COOLDOWN_CURRENT + 300))
            [ "$PENDING_COOLDOWN_CURRENT" -gt "$MAX_COOLDOWN" ] && PENDING_COOLDOWN_CURRENT=$MAX_COOLDOWN
            PENDING_COUNT=0; sleep_i "$check_interval"; continue
        fi
        RETRY_DELAY=$((15 * PENDING_COUNT)); [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120
    else
        PENDING_COUNT=0
        if [ "$RC" = "2" ] && [ -f "$CACHE_FILE" ]; then
            CACHED_URL=$(cat "$CACHE_FILE" 2>/dev/null)
            [ "$CACHED_URL" = "$AUTH_URL" ] && rm -f "$CACHE_FILE"
        fi
        if [ "$RC" = "2" ]; then
            TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
            if [ "$TIMEOUT_COUNT" -ge "$MAX_TIMEOUT" ]; then
                log_msg "连续 ${TIMEOUT_COUNT} 次认证请求超时，冷却 ${TIMEOUT_COOLDOWN_CURRENT} 秒"
                cooldown_wait "$username" "$password" "$TIMEOUT_COOLDOWN_CURRENT"
                TIMEOUT_COOLDOWN_CURRENT=$((TIMEOUT_COOLDOWN_CURRENT + 300))
                [ "$TIMEOUT_COOLDOWN_CURRENT" -gt "$MAX_COOLDOWN" ] && TIMEOUT_COOLDOWN_CURRENT=$MAX_COOLDOWN
                TIMEOUT_COUNT=0; sleep_i "$check_interval"; continue
            fi
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [ "$FAIL_COUNT" -ge "$MAX_FAIL" ]; then
                log_msg "连续 ${FAIL_COUNT} 次认证未成功，冷却 ${FAIL_COOLDOWN_SEC} 秒，请检查学号/密码/服务类型"
                cooldown_wait "$username" "$password" "$FAIL_COOLDOWN_SEC"
                FAIL_COUNT=0; sleep_i "$check_interval"; continue
            fi
        fi
        RETRY_DELAY=$((check_interval * (FAIL_COUNT + TIMEOUT_COUNT)))
        [ "$RETRY_DELAY" -lt 10 ] && RETRY_DELAY=10
        [ "$RETRY_DELAY" -gt 120 ] && RETRY_DELAY=120
    fi
    sleep_i "$RETRY_DELAY"
done
