package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	Timeout = 15 * time.Second
)

type LoginParams struct {
	Username        string
	Password        string
	ServiceType     string
	PasswordEncrypt string
}

type ServiceOption struct {
	Value string
	Label string
}

func main() {
	username := flag.String("u", "", "认证用户名")
	password := flag.String("p", "", "认证密码")
	serviceType := flag.String("s", "auto", "服务类型: auto(自动检测) / default(学生) / Teacher(教师) 等，可先运行 -l 查看可选值")
	persistent := flag.Bool("e", false, "启用持久化登录模式")
	manualURL := flag.String("m", "", "手动指定完整认证页面地址")
	listServices := flag.Bool("l", false, "仅列出认证页面提供的可选服务类型，然后退出")
	help := flag.Bool("h", false, "显示帮助信息")

	flag.Parse()

	if *help || (*username == "" && *password == "" && !*listServices) {
		fmt.Println("锐捷校园网认证客户端")
		fmt.Println("")
		fmt.Println("用法: ruijie [选项]")
		fmt.Println("")
		fmt.Println("选项:")
		fmt.Println("  -u string    认证用户名")
		fmt.Println("  -p string    认证密码")
		fmt.Println("  -s string    服务类型: auto(自动检测,默认) / default / Teacher ...")
		fmt.Println("  -m string    完整认证页面地址")
		fmt.Println("  -e           启用持久化登录模式")
		fmt.Println("  -l           列出认证页面上可选的服务类型后退出")
		fmt.Println("  -h           显示此帮助信息")
		fmt.Println("")
		fmt.Println("示例:")
		fmt.Println("  ruijie -l                                  # 先查看可选服务类型")
		fmt.Println("  ruijie -u 学号 -p 密码 -s default          # 指定服务类型认证")
		fmt.Println("  ruijie -u 学号 -p 密码 -s auto -e          # 自动检测并持久化在线")
		os.Exit(0)
	}

	var loginURL string
	if *manualURL != "" {
		loginURL = *manualURL
		fmt.Printf("使用手动指定的认证地址\n")
	} else {
		fmt.Println("尝试自动获取认证地址...")
		loginURL = getLoginURL()
		if loginURL == "" {
			if *listServices {
				fmt.Println("自动获取认证地址失败，请用 -m 指定完整认证地址")
				os.Exit(1)
			}
			fmt.Print("请输入认证地址: ")
			reader := bufio.NewReader(os.Stdin)
			input, _ := reader.ReadString('\n')
			loginURL = strings.TrimSpace(input)
			if loginURL == "" {
				fmt.Println("未输入认证地址，程序退出")
				return
			}
		}
	}
	fmt.Printf("认证地址: %s\n", loginURL)

	// redirectortosuccess.jsp 时先取真实 index.jsp 地址
	if strings.Contains(loginURL, "redirectortosuccess.jsp") {
		fmt.Println("检测到重定向页面，获取真实认证地址...")
		realURL := fetchRealLoginURL(loginURL)
		if realURL != "" {
			loginURL = realURL
			fmt.Printf("真实认证地址: %s\n", loginURL)
		} else {
			fmt.Println("无法获取真实认证地址，请使用 -m 参数手动指定")
			return
		}
	}
	// 从URL中提取queryString
	queryString := extractQueryStringFromURL(loginURL)
	if queryString == "" {
		fmt.Println("未能从URL中提取queryString")
		fmt.Println("请确保URL包含 wlanuserip 等参数")
	} else {
		fmt.Printf("提取到queryString (长度: %d)\n", len(queryString))
	}
	// ---- 自动/列出 service ----
	service := *serviceType
	options, err := fetchServiceOptions(loginURL, queryString)
	if *listServices {
		if err != nil || len(options) == 0 {
			fmt.Println("未能从认证页面解析到服务类型（页面可能是动态加载的），可尝试:")
			fmt.Println("  1. 浏览器打开认证页，查看页面源码中 service 相关的 select/option")
			fmt.Println("  2. 直接按经验填 default / Teacher / 电信 / 移动 / 联通 等值")
			os.Exit(1)
		}
		fmt.Println("认证页面提供的可选服务类型:")
		for _, o := range options {
			fmt.Printf("  %-20s %s\n", o.Value, o.Label)
		}
		os.Exit(0)
	}
	if service == "auto" || service == "" {
		if err == nil && len(options) > 0 {
			service = options[0].Value
			fmt.Println("检测到以下服务类型:")
			for _, o := range options {
				fmt.Printf("  %-20s %s\n", o.Value, o.Label)
			}
			fmt.Printf("自动选择第一个: %s（如需其他值请用 -s 指定）\n", service)
		} else {
			service = "default"
			fmt.Println("未能自动检测服务类型，回退为 default")
		}
	}


	formData := url.Values{}
	formData.Set("userId", *username)
	formData.Set("password", *password)
	formData.Set("service", service)
	formData.Set("queryString", queryString)
	formData.Set("operatorPwd", "")
	formData.Set("operatorUserId", "")
	formData.Set("validcode", "")
	formData.Set("passwordEncrypt", "false")

	if *persistent {
		fmt.Println("持久化模式已开启，每10秒检测一次")

		// 只在状态发生变化时输出。
		// 以前是无条件每 10 秒打一行"网络连接正常"——一天 8640 行，
		// 会把路由器上的连接日志刷满，真正的认证事件反而被埋掉。
		const minWait = 10 * time.Second
		const maxWait = 5 * time.Minute

		wait := minWait
		state := "" // "" 初始 / "online" 在线 / "offline" 离线

		for {
			if checkNetwork() {
				if state != "online" {
					if state == "offline" {
						fmt.Println("网络已恢复")
					} else {
						fmt.Println("网络连接正常")
					}
				}
				state = "online"
				wait = minWait
				time.Sleep(wait)
				continue
			}

			// ---- 离线：按退避策略重试认证 ----
			if state == "online" {
				fmt.Println("网络已断开，开始尝试重新认证")
			} else if state == "" {
				fmt.Println("网络未连接，开始认证")
			}
			state = "offline"

			ok := doLogin(loginURL, formData)

			// 只有 checkNetwork 确认恢复在线，才会在上面的分支把间隔重置回 10 秒。
			// 离线期间一律退避——这样即使认证接口误报成功，也不会每 10 秒猛打一次。
			// 注意: 真正的重连（doLogin）是立刻执行的，不受退避影响，
			// 退避只决定"下一次探测"等多久。
			if wait < maxWait {
				wait *= 2
				if wait > maxWait {
					wait = maxWait
				}
			}

			if ok {
				fmt.Printf("%.0f 秒后确认是否已恢复\n", wait.Seconds())
			} else {
				fmt.Printf("认证未成功，%.0f 秒后重试\n", wait.Seconds())
			}

			time.Sleep(wait)
		}
	} else {
		if !checkNetwork() {
			doLogin(loginURL, formData)
		} else {
			fmt.Println("已联网，无需认证")
		}
	}
}

// 抓取认证页面，解析可选的 service 类型
// 兼容三种常见写法：
//  1. <select name="service" ...><option value="default">学生</option>...</select>
//  2. <input type="hidden" name="service" value="default"/>
//  3. JS 中 service: 'default'  /  service = "default"
// 抓取认证页面，解析可选的 service 类型
// 优先级：
//  1. 调 InterFace.do?method=getServices 拿动态服务列表（最准确）
//  2. 静态页面 #serviceShowHide 内的 onclick="selectService('value','label',n)"
//  3. JS 中的 var services=[{...}] JSON
//  4. <select name="service"> 的 <option>
//  5. <input name="service"> / net_access_type 的 value
//  6. JS 中的 service: 'xxx'
func fetchServiceOptions(loginURL, queryString string) ([]ServiceOption, error) {
	// 1. 先尝试动态接口
	if opts, err := fetchServicesFromAPI(loginURL, queryString); err == nil && len(opts) > 0 {
		return opts, nil
	}

	// 2. 回退到静态页面解析
	client := &http.Client{Timeout: Timeout}
	req, err := http.NewRequest("GET", loginURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	req.Header.Set("Referer", loginURL)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	return parseServiceOptionsFromHTML(string(body)), nil
}

// 调用 eportal 的 getServices 接口获取动态服务列表
func fetchServicesFromAPI(loginURL, queryString string) ([]ServiceOption, error) {
	apiURL := buildEportalBase(loginURL) + "InterFace.do?method=getServices"

	form := url.Values{}
	form.Set("queryString", queryString)

	client := &http.Client{Timeout: Timeout}
	req, err := http.NewRequest("POST", apiURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	req.Header.Set("Referer", loginURL)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var result struct {
		ServiceJSON string `json:"serviceJson"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	if result.ServiceJSON == "" {
		return nil, fmt.Errorf("serviceJson 为空")
	}
	return parseServiceJSON(result.ServiceJSON), nil
}

// 解析 serviceJson 字符串为选项列表
// 例如: [{"serviceName":"default","serviceShowName":"学校_学生",...},...]
func parseServiceJSON(jsonStr string) []ServiceOption {
	var arr []map[string]interface{}
	if err := json.Unmarshal([]byte(jsonStr), &arr); err != nil {
		return nil
	}
	var out []ServiceOption
	seen := map[string]bool{}
	for _, item := range arr {
		name, _ := item["serviceName"].(string)
		show, _ := item["serviceShowName"].(string)
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, ServiceOption{Value: name, Label: strings.TrimSpace(show)})
	}
	return out
}

// 从静态 HTML 中解析服务选项
func parseServiceOptionsFromHTML(bodyStr string) []ServiceOption {
	var out []ServiceOption
	seen := map[string]bool{}
	add := func(v, label string) {
		v = strings.TrimSpace(v)
		if v == "" || seen[v] {
			return
		}
		seen[v] = true
		out = append(out, ServiceOption{Value: v, Label: strings.TrimSpace(label)})
	}

	// 1. #serviceShowHide 内的 selectService('value','label',n)
	selRe := regexp.MustCompile(`(?is)selectService\s*\(\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]?\d+['"]?\s*\)`)
	for _, sm := range selRe.FindAllStringSubmatch(bodyStr, -1) {
		add(sm[1], sm[2])
	}

	// 2. JS: var services=[{...}]
	if len(out) == 0 {
		servicesRe := regexp.MustCompile(`(?is)var\s+services\s*=\s*(\[.*?\])\s*;`)
		if m := servicesRe.FindStringSubmatch(bodyStr); len(m) > 1 {
			for _, o := range parseServiceJSON(m[1]) {
				add(o.Value, o.Label)
			}
		}
	}

	// 3. select[name=service] > option
	if len(out) == 0 {
		selectRe := regexp.MustCompile(`(?is)<select[^>]*(?:name|id)\s*=\s*["']?service["']?[^>]*>(.*?)</select>`)
		optRe := regexp.MustCompile(`(?is)<option[^>]*value\s*=\s*["']([^"']*)["'][^>]*>([^<]*)`)
		for _, m := range selectRe.FindAllStringSubmatch(bodyStr, -1) {
			for _, om := range optRe.FindAllStringSubmatch(m[1], -1) {
				add(om[1], om[2])
			}
		}
	}

	// 4. input[name=service] / input[name=net_access_type]
	if len(out) == 0 {
		inputRe := regexp.MustCompile(`(?is)<input[^>]*name\s*=\s*["']?(?:service|net_access_type)["']?[^>]*>`)
		valRe := regexp.MustCompile(`(?is)value\s*=\s*["']([^"']+)["']`)
		for _, im := range inputRe.FindAllStringSubmatch(bodyStr, -1) {
			if vm := valRe.FindStringSubmatch(im[0]); len(vm) > 1 {
				add(vm[1], "")
			}
		}
	}

	// 5. JS: service='default'
	if len(out) == 0 {
		jsRe := regexp.MustCompile(`(?i)service\s*[:=]\s*["']([A-Za-z0-9_\-\x{4e00}-\x{9fa5}]+)["']`)
		for _, jm := range jsRe.FindAllStringSubmatch(bodyStr, -1) {
			add(jm[1], "")
		}
	}

	return out
}

// 从认证地址推导出 eportal 根路径（以 / 结尾）
func buildEportalBase(loginURL string) string {
	base := loginURL
	if idx := strings.Index(base, "?"); idx != -1 {
		base = base[:idx]
	}
	base = strings.TrimSuffix(base, "/")

	if idx := strings.Index(base, "/eportal/"); idx != -1 {
		return base[:idx+len("/eportal/")]
	}
	if idx := strings.Index(base, "/eportal"); idx != -1 {
		return base[:idx+len("/eportal")] + "/"
	}
	// 没有 eportal 路径，取最后一级目录
	if idx := strings.LastIndex(base, "/"); idx != -1 {
		return base[:idx+1]
	}
	return base + "/"
}

// 执行登录认证
//
// 返回值表示"这次认证是否被确认成功"，持久化模式用它决定要不要退避重试。
// 命令行下的输出与以前完全一致。
func doLogin(loginURL string, formData url.Values) bool {
	fmt.Println("正在尝试认证...")

	targetURL := buildAuthURL(loginURL)
	fmt.Printf("认证请求URL: %s\n", targetURL)

	client := &http.Client{Timeout: Timeout}
	req, err := http.NewRequest("POST", targetURL, strings.NewReader(formData.Encode()))
	if err != nil {
		fmt.Printf("构建请求失败: %v\n", err)
		return false
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// 部分 eportal 会校验 Referer，带上认证页面地址
	req.Header.Set("Referer", loginURL)
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

	loginResp, err := client.Do(req)
	if err != nil {
		fmt.Printf("认证请求失败: %v\n", err)
		return false
	}
	defer loginResp.Body.Close()

	body, err := ioutil.ReadAll(loginResp.Body)
	if err != nil {
		fmt.Printf("读取响应失败: %v\n", err)
		return false
	}

	bodyStr := string(body)
	fmt.Printf("响应状态: %d\n", loginResp.StatusCode)
	if len(bodyStr) > 0 {
		fmt.Printf("响应内容: %s\n", bodyStr[:min(500, len(bodyStr))])
	}

	if loginResp.StatusCode == 200 {
		if strings.Contains(bodyStr, `"result":"success"`) ||
			strings.Contains(bodyStr, "登录成功") ||
			strings.Contains(bodyStr, "认证成功") {
			fmt.Println("认证成功！")
			return true
		} else if strings.Contains(bodyStr, `"result":"fail"`) ||
			strings.Contains(bodyStr, "失败") {
			msg := extractErrorMessage(bodyStr)
			fmt.Printf("认证失败: %s\n", msg)
			return false
		} else if strings.Contains(bodyStr, "上网") || strings.Contains(bodyStr, "已登录") {
			fmt.Println("认证成功！")
			return true
		} else {
			fmt.Println("认证请求已提交，请检查是否能正常上网")
			fmt.Println("如果无法上网，请检查:")
			fmt.Println("  1. queryString是否完整")
			fmt.Println("  2. 服务类型是否正确 (可运行 ruijie -l 查看)")
			fmt.Println("  3. 用户名密码是否正确")
			// 响应里没有明确的成功/失败标志，保守地当作"未确认"，
			// 让持久化模式走退避，而不是每 10 秒猛打一次
			return false
		}
	}

	fmt.Printf("认证请求失败 (HTTP %d)\n", loginResp.StatusCode)
	return false
}

func buildAuthURL(loginURL string) string {
	return buildEportalBase(loginURL) + "InterFace.do?method=login"
}

func fetchRealLoginURL(redirectURL string) string {
	client := &http.Client{Timeout: Timeout}
	resp, err := client.Get(redirectURL)
	if err != nil {
		fmt.Printf("获取重定向页面失败: %v\n", err)
		return ""
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		fmt.Printf("读取重定向页面失败: %v\n", err)
		return ""
	}
	bodyStr := string(body)

	res := []string{
		`location\.href\s*=\s*['"]([^'"]+)['"]`,
		`window\.location\s*=\s*['"]([^'"]+)['"]`,
		`top\.self\.location\.href\s*=\s*['"]([^'"]+)['"]`,
	}
	for _, pattern := range res {
		re := regexp.MustCompile(pattern)
		if m := re.FindStringSubmatch(bodyStr); len(m) > 1 {
			return m[1]
		}
	}
	return ""
}

func checkNetwork() bool {
	client := &http.Client{
		Timeout: Timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	checkURLs := []string{"http://www.baidu.com", "http://www.qq.com", "http://www.163.com"}
	for _, u := range checkURLs {
		resp, err := client.Get(u)
		if err != nil {
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode == 204 {
			return true
		}
		if resp.StatusCode == 302 || resp.StatusCode == 301 {
			return false
		}
		if resp.StatusCode == 200 {
			body, _ := ioutil.ReadAll(resp.Body)
			bodyStr := string(body)
			if strings.Contains(bodyStr, "eportal") || strings.Contains(bodyStr, "认证") {
				return false
			}
			return true
		}
	}
	return false
}

func getLoginURL() string {
	client := &http.Client{
		Timeout: Timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	gatewayIPs := []string{
		"http://172.17.211.2",
		"http://10.0.0.1",
		"http://192.168.1.1",
	}

	for _, ip := range gatewayIPs {
		resp, err := client.Get(ip)
		if err != nil {
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode == 302 || resp.StatusCode == 301 {
			loginURL := resp.Header.Get("Location")
			if loginURL != "" && strings.Contains(loginURL, "eportal") {
				return loginURL
			}
		}

		if resp.StatusCode == 200 {
			body, _ := ioutil.ReadAll(resp.Body)
			bodyStr := string(body)
			if strings.Contains(bodyStr, "eportal") {
				re := regexp.MustCompile(`<form[^>]*action=["']([^"']+)["']`)
				matches := re.FindStringSubmatch(bodyStr)
				if len(matches) > 1 {
					actionURL := matches[1]
					if strings.HasPrefix(actionURL, "http") {
						return actionURL
					}
					return ip + actionURL
				}
				return ip + "/eportal/index.jsp"
			}
		}
	}
	return ""
}

func extractQueryStringFromURL(loginURL string) string {
	u, err := url.Parse(loginURL)
	if err == nil {
		q := u.Query()
		if qs := q.Get("queryString"); qs != "" {
			return qs
		}
		if q.Get("wlanuserip") != "" {
			params := url.Values{}
			for key, values := range q {
				if key != "queryString" {
					for _, value := range values {
						params.Add(key, value)
					}
				}
			}
			return params.Encode()
		}
	}

	idx := strings.Index(loginURL, "?")
	if idx != -1 {
		queryPart := loginURL[idx+1:]
		if !strings.Contains(queryPart, "queryString=") {
			return queryPart
		}
	}

	re := regexp.MustCompile(`queryString=([^&]+)`)
	if m := re.FindStringSubmatch(loginURL); len(m) > 1 {
		return m[1]
	}
	return ""
}

func extractErrorMessage(body string) string {
	if m := regexp.MustCompile(`"message":"([^"]+)"`).FindStringSubmatch(body); len(m) > 1 {
		return m[1]
	}
	if m := regexp.MustCompile(`<p[^>]*>([^<]+)</p>`).FindStringSubmatch(body); len(m) > 1 {
		return m[1]
	}
	return "未知错误"
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
