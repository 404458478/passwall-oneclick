#!/bin/sh
set -eu

CONTROLLER="/usr/lib/lua/luci/controller/passwall_socks_batch.lua"
MODEL="/usr/lib/lua/luci/model/cbi/passwall/client/socks_batch.lua"
LAN_MODEL="/usr/lib/lua/luci/model/cbi/passwall/client/lan_batch.lua"
LAN_DELETE="/usr/lib/lua/luci/model/cbi/passwall/client/lan_delete.lua"
SOCKS_DELETE="/usr/lib/lua/luci/model/cbi/passwall/client/socks_delete.lua"
XRAY_UTIL="/usr/lib/lua/luci/passwall/util_xray.lua"

fail() {
    echo "错误：$*" >&2
    exit 1
}

clear_luci_cache() {
    for file in /tmp/luci-indexcache*; do
        [ -f "$file" ] && rm -f "$file"
    done
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
}

fix_sk5() {
    dns="${1:-223.5.5.5}"
    [ "$(id -u)" = "0" ] || fail "请使用 root 运行"
    [ -f "/etc/config/passwall" ] || fail "未检测到 PassWall"
    printf '%s\n' "$dns" |
        awk -F. 'NF != 4 { exit 1 }
            { for (i = 1; i <= 4; i++)
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }' ||
        fail "DNS 地址无效：$dns"

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="/root/passwall.bak.sk5fix.$stamp"
    cp -p /etc/config/passwall "$backup"

    uci set passwall.@global[0].enabled='1'
    uci set passwall.@global[0].use_gfw_list='0'
    uci set passwall.@global[0].chn_list='0'
    uci set passwall.@global[0].tcp_proxy_mode='proxy'
    uci set passwall.@global[0].udp_proxy_mode='proxy'
    uci set passwall.@global[0].dns_redirect='1'
    uci set passwall.@global[0].dns_shunt='chinadns-ng'
    uci set passwall.@global[0].dns_mode='tcp'
    uci set passwall.@global[0].direct_dns_mode='tcp'
    uci set passwall.@global[0].direct_dns="$dns"
    uci set passwall.@global[0].remote_dns="$dns"
    uci commit passwall

    [ "$(uci -q get passwall.@global[0].use_gfw_list)" = "0" ] ||
        fail "GFW 列表关闭失败"
    [ "$(uci -q get passwall.@global[0].chn_list)" = "0" ] ||
        fail "中国列表关闭失败"
    [ "$(uci -q get passwall.@global[0].tcp_proxy_mode)" = "proxy" ] ||
        fail "TCP 全局代理设置失败"
    [ "$(uci -q get passwall.@global[0].udp_proxy_mode)" = "proxy" ] ||
        fail "UDP 全局代理设置失败"
    [ "$(uci -q get passwall.@global[0].direct_dns)" = "$dns" ] ||
        fail "直连 DNS 设置失败"
    [ "$(uci -q get passwall.@global[0].remote_dns)" = "$dns" ] ||
        fail "远程 DNS 设置失败"

    /etc/init.d/passwall restart

    echo "SK5 全局 TCP/UDP 代理模式已启用。"
    echo "DNS：$dns（TCP）"
    echo "TCP/UDP：全局经过 SK5"
    echo "备份：$backup"
}

fix_xray_source_rules() {
    [ -f "$XRAY_UTIL" ] || return 0
    grep -Fq \
        'if not domains and not ip and (protocols or source) then' \
        "$XRAY_UTIL" && return 0
    grep -Fq 'if not domains and not ip and protocols then' "$XRAY_UTIL" ||
        fail "Xray 分流规则兼容补丁无法应用：PassWall 版本不匹配"

    cp -p "$XRAY_UTIL" "$XRAY_UTIL.bak.lanbatch.$stamp"
    sed -i \
        's/if not domains and not ip and protocols then/if not domains and not ip and (protocols or source) then/' \
        "$XRAY_UTIL"
    grep -Fq \
        'if not domains and not ip and (protocols or source) then' \
        "$XRAY_UTIL" ||
        fail "Xray 分流规则兼容补丁写入失败"
    lua -e "assert(loadfile('$XRAY_UTIL'))" ||
        fail "修改后的 util_xray.lua 语法检查失败"
}

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
PassWall SOCKS5 批量导入安装脚本

用法：
  sh passwall-socks5-batch.sh             安装或更新
  sh passwall-socks5-batch.sh --uninstall 卸载导入页面
  sh passwall-socks5-batch.sh --fix-sk5 [DNS]
                                          修复 SK5 的 DNS 和 UDP 兼容性
                                          默认 DNS：223.5.5.5

安装后进入：
  服务 -> PassWall -> SOCKS5 批量导入
  服务 -> PassWall -> 内网IP导入
卸载不会删除已经导入的节点。
EOF
        exit 0
        ;;
    --fix-sk5)
        fix_sk5 "${2:-223.5.5.5}"
        exit 0
        ;;
    --uninstall)
        [ "$(id -u)" = "0" ] || fail "请使用 root 运行"
        rm -f "$CONTROLLER" "$MODEL" "$LAN_MODEL" "$LAN_DELETE" "$SOCKS_DELETE"
        clear_luci_cache
        echo "已卸载批量导入页面，现有 PassWall 节点和分流规则未改动。"
        exit 0
        ;;
    "")
        ;;
    *)
        fail "未知参数：$1，使用 --help 查看帮助"
        ;;
esac

[ "$(id -u)" = "0" ] || fail "请使用 root 运行"
command -v lua >/dev/null 2>&1 || fail "未找到 Lua"
[ -f "/etc/config/passwall" ] || fail "未检测到 PassWall"
[ -f "/usr/lib/lua/luci/passwall/api.lua" ] ||
    fail "仅支持传统 PassWall，不支持 PassWall2"
[ -f "/usr/lib/lua/luci/model/cbi/passwall/client/shunt_rules.lua" ] ||
    fail "当前 PassWall 不支持 Sing-Box/Xray 分流规则"

stamp="$(date +%Y%m%d-%H%M%S)"
tmp_dir="/tmp/passwall-socks5-batch.$$"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
mkdir -p "$tmp_dir"

cat >"$tmp_dir/controller.lua" <<'EOF'
module("luci.controller.passwall_socks_batch", package.seeall)

function index()
    local api = require "luci.passwall.api"
    local socks_entry = entry({
        "admin", "services", api.appname, "socks_batch"
    }, firstchild(), "SOCKS5 批量导入", 4)
    socks_entry.dependent = true
    socks_entry.acl_depends = { "luci-app-passwall" }

    local socks_import = entry({
        "admin", "services", api.appname, "socks_batch", "import"
    }, form(api.appname .. "/client/socks_batch"), "批量导入", 1)
    socks_import.leaf = true
    socks_import.acl_depends = { "luci-app-passwall" }

    local socks_check = entry({
        "admin", "services", api.appname, "socks_batch", "check"
    }, form(api.appname .. "/client/socks_batch"), "检测与修复", 3)
    socks_check.leaf = true
    socks_check.acl_depends = { "luci-app-passwall" }

    local socks_delete = entry({
        "admin", "services", api.appname, "socks_batch", "delete"
    }, form(api.appname .. "/client/socks_batch"), "批量删除", 2)
    socks_delete.leaf = true
    socks_delete.acl_depends = { "luci-app-passwall" }

    local lan_entry = entry({
        "admin", "services", api.appname, "lan_batch"
    }, firstchild(), "内网IP导入", 5)
    lan_entry.dependent = true
    lan_entry.acl_depends = { "luci-app-passwall" }

    local lan_import = entry({
        "admin", "services", api.appname, "lan_batch", "import"
    }, form(api.appname .. "/client/lan_batch"), "批量导入", 1)
    lan_import.leaf = true
    lan_import.acl_depends = { "luci-app-passwall" }

    local lan_delete = entry({
        "admin", "services", api.appname, "lan_batch", "delete"
    }, form(api.appname .. "/client/lan_batch"), "IP删除", 2)
    lan_delete.leaf = true
    lan_delete.acl_depends = { "luci-app-passwall" }
end
EOF

cat >"$tmp_dir/model.lua" <<'EOF'
local api = require "luci.passwall.api"
if type(api.set_default_cbi) == "function" then
    api.set_default_cbi()
end

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local path_info = http.getenv("PATH_INFO") or ""
local mode = path_info:match("/socks_batch/([^/]+)") or "import"

local mode_titles = {
    import = "批量导入 SK5",
    check = "检测与修复 SK5",
    delete = "批量删除 SK5"
}
local m = SimpleForm("socks_batch", translate(mode_titles[mode]))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate(
    mode == "check" and "开始检测" or
    mode == "delete" and "删除所选 SK5" or "开始导入"
)
if mode == "import" then
    m.description = translate(
        "每行一个节点。支持 HOST:PORT:USER:PASSWORD、HOST:PORT、" ..
        "以及 socks5:// / socks5h:// 链接；以 # 开头的行会忽略。"
    )
elseif mode == "check" then
    m.description = translate(
        "勾选节点后执行检测；不可用节点会高亮，并提供原位修改。"
    )
else
    m.description = translate(
        "勾选要删除的 SK5 节点。删除时会同步清理分流节点中的绑定。"
    )
end

local s = m:section(SimpleSection)

if mode == "check" then
    local operation_opt =
        s:option(ListValue, "operation", translate("操作类型"))
    operation_opt:value("check", translate("批量检测 SK5 是否可用"))
    operation_opt:value("edit", translate("原位修改 SK5 节点"))
    operation_opt.default = "check"
elseif mode == "import" then
    local o = s:option(TextValue, "nodes", translate("节点列表"))
    o.rows = 18
    o.wrap = "off"
    o.rmempty = false

    local overwrite_opt = s:option(Flag, "overwrite", translate("导入覆盖"))
    overwrite_opt.description = translate(
        "启用后，地址、端口和用户名相同的节点会覆盖密码；" ..
        "未启用时保持原来的重复跳过。节点 ID、备注和分流绑定不变。"
    )
end

local socks_nodes = {}
uci:foreach("passwall", "nodes", function(node)
    if node.protocol == "socks" then
        socks_nodes[#socks_nodes + 1] = {
            id = node[".name"],
            remarks = node.remarks or node[".name"],
            address = node.address or "",
            port = node.port or ""
        }
    end
end)
table.sort(socks_nodes, function(a, b)
    if a.remarks == b.remarks then
        return a.id < b.id
    end
    return a.remarks < b.remarks
end)

if mode == "check" or mode == "delete" then
local select_opt = s:option(
    DummyValue, "delete_select",
    translate(mode == "delete" and "删除快速选择" or "节点快速选择")
)
select_opt.rawhtml = true
select_opt.default = [=[
<div style="display:flex;align-items:center;gap:1em;flex-wrap:wrap">
    <label style="display:inline-flex;align-items:center;gap:.4em;cursor:pointer">
        <input id="socks-batch-select-all" type="checkbox" class="cbi-input-checkbox"
            onclick="var on=this.checked;(function(on){var r=document.getElementById('cbid.socks_batch.1.delete_nodes');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.socks_batch.1.delete_nodes&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked!==on)a[i].click()}})(on);" />
        <span>全部选择</span>
    </label>
    <button type="button" class="cbi-button cbi-button-reset"
        onclick="document.getElementById('socks-batch-select-all').checked=false;(function(){var r=document.getElementById('cbid.socks_batch.1.delete_nodes');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.socks_batch.1.delete_nodes&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked)a[i].click()}})();return false;">
        全部取消选择
    </button>
</div>
]=]

local delete_nodes_opt = s:option(
    MultiValue, "delete_nodes",
    translate(mode == "delete" and "要删除的 SK5 节点" or "要检测的 SK5 节点")
)
delete_nodes_opt.widget = "checkbox"
for _, node in ipairs(socks_nodes) do
    delete_nodes_opt:value(
        node.id,
        string.format("%s | %s:%s", node.remarks, node.address, node.port)
    )
end

if mode == "delete" then
    local delete_confirm_opt =
        s:option(Flag, "delete_confirm", translate("确认删除所选 SK5"))
end
end

if mode == "check" then
local edit_title_opt =
    s:option(DummyValue, "edit_title", translate("节点原位修改"))
edit_title_opt.rawhtml = true
edit_title_opt.default = [=[
<style>
#cbi-socks_batch-1-operation,
#cbi-socks_batch-1-edit_title,
#cbi-socks_batch-1-edit_node,
#cbi-socks_batch-1-edit_address,
#cbi-socks_batch-1-edit_port,
#cbi-socks_batch-1-edit_username,
#cbi-socks_batch-1-edit_password { display:none }
</style>
<div>点击不可用节点的“原位修改”按钮后，才会显示节点信息修改框。</div>
]=]

local edit_node_opt =
    s:option(Value, "edit_node", translate("节点 ID（自动填充）"))

local edit_address_opt =
    s:option(Value, "edit_address", translate("地址"))

local edit_port_opt =
    s:option(Value, "edit_port", translate("端口"))

local edit_username_opt =
    s:option(Value, "edit_username", translate("用户名"))

local edit_password_opt =
    s:option(Value, "edit_password", translate("新密码"))
edit_password_opt.password = true
edit_password_opt.placeholder = translate("留空保持原密码")
end

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function valid_ipv4(host)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return true
    end
    for _, value in ipairs({ a, b, c, d }) do
        local number = tonumber(value)
        if not number or number < 0 or number > 255 then
            return false
        end
    end
    return true
end

local function valid_host(host)
    if not host or host == "" or #host > 253 then
        return false
    end
    if host:find(":", 1, true) then
        return true
    end
    if not valid_ipv4(host) then
        return false
    end
    return host:match("^[A-Za-z0-9][A-Za-z0-9%.%-]*$") ~= nil
end

local function parse_url(line)
    local body = line:match("^socks5h?://(.+)$")
    if not body then
        return nil
    end

    local auth, authority = body:match("^(.-)@(.+)$")
    if not authority then
        auth = nil
        authority = body
    end

    local host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
    if not host then
        host, port = authority:match("^([^:]+):(%d+)$")
    end

    local username, password = "", ""
    if auth then
        username, password = auth:match("^([^:]*):(.*)$")
        if not username then
            return nil
        end
    end

    return host, port, username, password
end

local function parse_line(line)
    local host, port, username, password = parse_url(line)
    if not host then
        host, port, username, password =
            line:match("^([^:]+):(%d+):([^:]*):(.*)$")
    end
    if not host then
        host, port = line:match("^([^:]+):(%d+)$")
        username, password = "", ""
    end

    local port_number = tonumber(port or "")
    if not valid_host(host) or not port_number or
        port_number < 1 or port_number > 65535 then
        return nil
    end

    return {
        address = host,
        port = tostring(port_number),
        username = username or "",
        password = password or ""
    }
end

local function has_core(name)
    if type(api.finded_com) == "function" and api.finded_com(name) then
        return true
    end
    return type(api.is_finded) == "function" and api.is_finded(name)
end

local function selected_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            result[#result + 1] = tostring(item)
        end
    elseif type(value) == "string" then
        for item in value:gmatch("%S+") do
            result[#result + 1] = item
        end
    end
    return result
end

local function html_escape(value)
    return tostring(value or "")
        :gsub("&", "&amp;")
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
end

local function edit_button(node)
    local attributes = string.format(
        'data-node="%s" data-address="%s" data-port="%s" data-username="%s"',
        html_escape(node[".name"]),
        html_escape(node.address),
        html_escape(node.port),
        html_escape(node.username)
    )
    return '<button type="button" class="cbi-button cbi-button-edit" ' ..
        attributes .. ' onclick="(function(b){' ..
        "var f=function(k,v){var e=document.getElementsByName('cbid.socks_batch.1.'+k)[0]||" ..
        "document.getElementById('cbid.socks_batch.1.'+k);if(e){" ..
        "e.value=v;e.dispatchEvent(new Event('input',{bubbles:true}));" ..
        "e.dispatchEvent(new Event('change',{bubbles:true}))}};" ..
        "var o=document.getElementsByName('cbid.socks_batch.1.operation')[0]||" ..
        "document.getElementById('cbid.socks_batch.1.operation');if(o){" ..
        "o.value='edit';o.dispatchEvent(new Event('change',{bubbles:true}))}" ..
        "f('edit_node',b.dataset.node);f('edit_address',b.dataset.address);" ..
        "f('edit_port',b.dataset.port);f('edit_username',b.dataset.username);" ..
        "f('edit_password','');var t=document.getElementById('cbid.socks_batch.1.edit_node')||" ..
        "document.getElementsByName('cbid.socks_batch.1.edit_node')[0];" ..
        "var ks=['edit_title','edit_node','edit_address','edit_port','edit_username','edit_password'];" ..
        "for(var i=0;i<ks.length;i++){var p=document.getElementById('cbi-socks_batch-1-'+ks[i]);if(p)p.style.display='block'}" ..
        "var sb=document.querySelector('.cbi-page-actions input[type=submit],.cbi-page-actions button[type=submit]');" ..
        "if(sb){if(sb.tagName==='INPUT')sb.value='保存节点修改';else sb.textContent='保存节点修改'}" ..
        "if(t)t.scrollIntoView({behavior:'smooth',block:'center'});" ..
        '})(this)">' .. translate("原位修改") .. "</button>"
end

local function check_socks(self, data)
    local current_nodes = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "socks" then
            current_nodes[#current_nodes + 1] = node
        end
    end)
    local known = {}
    for _, node in ipairs(current_nodes) do
        known[node[".name"]] = node
    end

    local selected = {}
    for _, id in ipairs(selected_list(data.delete_nodes)) do
        if known[id] then
            selected[#selected + 1] = known[id]
        end
    end
    if #selected == 0 then
        m.message = translate("没有勾选有效的 SK5 节点。")
        return true
    end

    local function quote(value)
        return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
    end

    local sys = require("luci.sys")
    local dir = string.format(
        "/tmp/passwall-skcheck-%d-%06d",
        os.time(), math.random(0, 999999)
    )
    if sys.call(
        "umask 077; mkdir -p " .. quote(dir) ..
        " && chmod 700 " .. quote(dir)
    ) ~= 0 then
        m.message = translate("无法创建临时检测目录。")
        return true
    end

    local script = dir .. "/run.sh"
    local handle, open_error = io.open(script, "w")
    if not handle then
        m.message = translate("无法创建检测脚本：") .. tostring(open_error)
        return true
    end

    handle:write("#!/bin/sh\n")
    local files = {}
    for index, node in ipairs(selected) do
        local result = string.format("%s/%03d.out", dir, index)
        files[#files + 1] = result
        local proxy = tostring(node.address or "") .. ":" ..
            tostring(node.port or "")
        local auth = tostring(node.username or "") .. ":" ..
            tostring(node.password or "")
        handle:write(
            "( out=$(/usr/bin/curl -sS --connect-timeout 5 --max-time 10 " ..
            "--proxy-user " .. quote(auth) ..
            " --socks5-hostname " .. quote(proxy) ..
            " -o /dev/null -w '\\nCHECK_RESULT:%{http_code}:%{time_total}' " ..
            quote("https://www.baidu.com") ..
            " 2>&1); rc=$?; printf 'CHECK_RC:%s\\nCHECK_OUT:%s\\n' " ..
            "\"$rc\" \"$out\" > " .. quote(result) .. " ) &\n"
        )
    end
    handle:write("wait\n")
    handle:close()
    sys.call("chmod 600 " .. quote(script))
    sys.call("/bin/sh " .. quote(script))

    local rows = {}
    local available = 0
    for index, node in ipairs(selected) do
        local content = ""
        local result_handle = io.open(files[index], "r")
        if result_handle then
            content = result_handle:read("*a") or ""
            result_handle:close()
        end
        local rc = tonumber(content:match("CHECK_RC:(%d+)"))
        local code, total =
            content:match("CHECK_RESULT:(%d+):([%d%.]+)")
        local ok = rc == 0 and code and code ~= "000"
        local detail
        if ok then
            available = available + 1
            detail = string.format(
                "HTTP %s，%d ms", code,
                math.floor((tonumber(total) or 0) * 1000 + 0.5)
            )
        else
            detail = translate("连接或认证失败")
        end
        local remarks = html_escape(node.remarks or node[".name"])
        local address = html_escape(
            tostring(node.address or "") .. ":" .. tostring(node.port or "")
        )
        local row_style = ok and
            "background:#eaf7ed;color:#176b2c" or
            "background:#ffe3e3;color:#9b1c1c;font-weight:600"
        rows[#rows + 1] = string.format(
            '<tr style="%s"><td>%s</td><td>%s</td><td>%s</td>' ..
            "<td>%s</td><td>%s</td></tr>",
            row_style, remarks, address,
            ok and translate("可用") or translate("不可用"),
            detail, ok and "" or edit_button(node)
        )
    end
    sys.call("rm -rf " .. quote(dir))

    local shown = {}
    for index = 1, math.min(#rows, 100) do
        shown[#shown + 1] = rows[index]
    end
    m.message = string.format(
        translate("检测完成：可用 %d / %d。"), available, #selected
    ) .. '<table class="cbi-section-table" style="width:100%;margin-top:.6em">' ..
        "<thead><tr><th>节点</th><th>地址</th><th>状态</th>" ..
        "<th>结果</th><th>操作</th></tr></thead><tbody>" ..
        table.concat(shown) .. "</tbody></table>"
    if #rows > #shown then
        m.message = m.message .. "<br />" ..
            string.format(translate("其余 %d 条未显示。"), #rows - #shown)
    end
    return true
end

local function edit_socks(self, data)
    local id = trim(data.edit_node)
    local node
    uci:foreach("passwall", "nodes", function(item)
        if item[".name"] == id and item.protocol == "socks" then
            node = item
        end
    end)
    if not node then
        m.message = translate("没有找到要修改的 SK5 节点。")
        return true
    end

    local address = trim(data.edit_address)
    local port = tonumber(trim(data.edit_port))
    if address == "" or not valid_host(address) then
        m.message = translate("节点地址格式无效。")
        return true
    end
    if not port or port < 1 or port > 65535 then
        m.message = translate("节点端口无效。")
        return true
    end

    local sys = require("luci.sys")
    local backup = "/root/passwall.bak.sk5edit." ..
        os.date("%Y%m%d-%H%M%S")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        m.message = translate("备份 PassWall 配置失败，本次未修改。")
        return true
    end

    uci:set("passwall", id, "address", address)
    uci:set("passwall", id, "port", tostring(port))
    uci:set("passwall", id, "username", trim(data.edit_username))
    local password = tostring(data.edit_password or "")
    local password_changed = password ~= ""
    if password_changed then
        uci:set("passwall", id, "password", password)
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，本次修改已撤销。")
        return true
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    m.message = string.format(
        translate("节点已修改：%s，地址 %s:%d，密码%s。"),
        node.remarks or id, address, port,
        password_changed and translate("已更新") or translate("保持不变")
    )
    return true
end

local function delete_socks(self, data)
    if data.delete_confirm ~= "1" then
        m.message = translate("请先勾选“确认删除所选 SK5”。")
        return true
    end

    local current_nodes = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "socks" then
            current_nodes[#current_nodes + 1] = {
                id = node[".name"],
                remarks = node.remarks or node[".name"]
            }
        end
    end)
    table.sort(current_nodes, function(a, b)
        if a.remarks == b.remarks then
            return a.id < b.id
        end
        return a.remarks < b.remarks
    end)

    local known = {}
    for _, node in ipairs(current_nodes) do
        known[node.id] = node
    end
    local selected = {}
    local selected_ids = {}
    for _, id in ipairs(selected_list(data.delete_nodes)) do
        if known[id] and not selected[id] then
            selected[id] = true
            selected_ids[#selected_ids + 1] = id
        end
    end
    if #selected_ids == 0 then
        m.message = translate("没有勾选有效的 SK5 节点。")
        return true
    end

    local remaining = {}
    for _, node in ipairs(current_nodes) do
        if not selected[node.id] then
            remaining[#remaining + 1] = node
        end
    end

    local shunt_ids = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "_shunt" then
            shunt_ids[#shunt_ids + 1] = node[".name"]
        end
    end)

    local sys = require("luci.sys")
    local backup = "/root/passwall.bak.skdelete." ..
        os.date("%Y%m%d-%H%M%S")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        m.message = translate("备份 PassWall 配置失败，本次未删除。")
        return true
    end

    local removed_bindings, updated_defaults, defaults_reset = 0, 0, 0
    for _, shunt_id in ipairs(shunt_ids) do
        local options = uci:get_all("passwall", shunt_id) or {}
        for option, value in pairs(options) do
            if option ~= "default_node" and
                type(value) == "string" and selected[value] then
                uci:delete("passwall", shunt_id, option)
                removed_bindings = removed_bindings + 1
            end
        end

        local default_node =
            uci:get("passwall", shunt_id, "default_node")
        if default_node and selected[default_node] then
            if remaining[1] then
                uci:set(
                    "passwall", shunt_id, "default_node",
                    remaining[1].id
                )
                updated_defaults = updated_defaults + 1
            else
                uci:delete("passwall", shunt_id, "default_node")
                defaults_reset = defaults_reset + 1
            end
        end
    end

    local active_node = uci:get("passwall", "@global[0]", "node")
    if active_node and selected[active_node] then
        if remaining[1] then
            uci:set(
                "passwall", "@global[0]", "node",
                remaining[1].id
            )
        elseif shunt_ids[1] then
            uci:set("passwall", "@global[0]", "node", shunt_ids[1])
        else
            uci:delete("passwall", "@global[0]", "node")
        end
    end

    for _, id in ipairs(selected_ids) do
        uci:delete("passwall", id)
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，节点删除已撤销。")
        return true
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    m.message = string.format(
        translate(
            "删除完成：节点 %d 个，清理规则绑定 %d 个，" ..
            "更新默认出口 %d 个，重置默认出口 %d 个。"
        ),
        #selected_ids, removed_bindings,
        updated_defaults, defaults_reset
    )
    return true
end

function m.handle(self, state, data)
    if state ~= FORM_VALID then
        return true
    end

    if mode == "delete" then
        return delete_socks(self, data)
    end
    if mode == "check" then
        if data.operation == "edit" then
            return edit_socks(self, data)
        end
        return check_socks(self, data)
    end

    local value = data.nodes or ""
    local overwrite = data.overwrite == "1"
    local imported, invalid, duplicated, overwritten = 0, 0, 0, 0
    local seen = {}
    local existing = {}
    local pending = {}

    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "socks" then
            local key = (node.address or "") .. "|" ..
                (node.port or "") .. "|" .. (node.username or "")
            seen[key] = true
            existing[key] = {
                id = node[".name"],
                password = node.password or ""
            }
        end
    end)

    for line in (value .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" and not line:match("^#") then
            local node = parse_line(line)
            if not node then
                invalid = invalid + 1
            else
                local key = node.address .. "|" ..
                    node.port .. "|" .. node.username
                if seen[key] then
                    if overwrite and existing[key] then
                        if existing[key].password ~= node.password then
                            if not uci:set(
                                "passwall", existing[key].id,
                                "password", node.password
                            ) then
                                uci:revert("passwall")
                                m.message = translate(
                                    "覆盖节点密码失败，本次导入已撤销。"
                                )
                                return true
                            end
                            existing[key].password = node.password
                            overwritten = overwritten + 1
                        else
                            duplicated = duplicated + 1
                        end
                    else
                        duplicated = duplicated + 1
                    end
                else
                    seen[key] = true
                    pending[#pending + 1] = node
                end
            end
        end
    end

    if #pending > 500 then
        m.message = translate("单次最多导入 500 条节点，本次未写入。")
        return true
    end

    local node_type
    if #pending > 0 then
        if has_core("sing-box") then
            node_type = "sing-box"
        elseif has_core("xray") then
            node_type = "Xray"
        elseif has_core("ipt2socks") then
            node_type = "Socks"
        else
            m.message = translate("未检测到 sing-box、Xray 或 ipt2socks，无法导入 SOCKS5 节点。")
            return true
        end
    end

    local base = os.time()
    local suffix = 0
    for _, node in ipairs(pending) do
        local id
        repeat
            suffix = suffix + 1
            id = string.format("batch_%d_%d", base, suffix)
        until not uci:get("passwall", id)

        local created = uci:section("passwall", "nodes", id, {
            type = node_type,
            protocol = "socks",
            remarks = string.format("SK5-%03d", imported + 1),
            address = node.address,
            port = node.port,
            username = node.username,
            password = node.password
        })

        if not created then
            uci:revert("passwall")
            m.message = translate("写入节点失败，本次导入已撤销。")
            return true
        end
        imported = imported + 1
    end

    if (imported > 0 or overwritten > 0) and
        not uci:commit("passwall") then
        uci:revert("passwall")
        m.message = translate("配置提交失败，本次导入已撤销。")
        return true
    end

    m.message = string.format(
        translate(
            "导入完成：新增 %d 条，覆盖 %d 条，" ..
            "重复跳过 %d 条，格式错误 %d 条。"
        ),
        imported, overwritten, duplicated, invalid
    )
    return true
end

if type(api.return_map) == "function" then
    return api.return_map(m)
end
return m
EOF

cat >"$tmp_dir/lan_model.lua" <<'EOF'
local api = require "luci.passwall.api"
if type(api.set_default_cbi) == "function" then
    api.set_default_cbi()
end

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local path_info = http.getenv("PATH_INFO") or ""
local mode = path_info:match("/lan_batch/([^/]+)") or "import"

local mode_titles = {
    import = "批量导入内网IP",
    delete = "IP删除"
}
local m = SimpleForm("lan_batch", translate(mode_titles[mode]))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate(mode == "delete" and "删除所选 IP" or "开始导入")
if mode == "delete" then
    m.description = translate("勾选要删除的内网 IP/CIDR。")
else
    m.description = translate(
        "每行或每个空白分隔项填写一个源 IP/CIDR，也可填写 geoip:private。" ..
        "每个来源会生成一条独立的 Sing-Box/Xray 分流规则。"
    )
end

local s = m:section(SimpleSection)

if mode == "import" then
local nodes = {}
local socks_nodes = {}
uci:foreach("passwall", "nodes", function(node)
    if node.protocol == "_shunt" then
        nodes[#nodes + 1] = {
            id = node[".name"],
            remarks = node.remarks or node[".name"]
        }
    elseif node.protocol == "socks" then
        socks_nodes[#socks_nodes + 1] = {
            id = node[".name"],
            remarks = node.remarks or node[".name"]
        }
    end
end)
table.sort(socks_nodes, function(a, b)
    if a.remarks == b.remarks then
        return a.id < b.id
    end
    return a.remarks < b.remarks
end)

local node_opt = s:option(ListValue, "shunt_node", translate("分流节点"))
for _, node in ipairs(nodes) do
    node_opt:value(node.id, node.remarks)
end
if #nodes > 0 then
    node_opt.default = nodes[1].id
else
    node_opt:value("", translate("未找到分流节点"))
end

local target_opt = s:option(ListValue, "target", translate("绑定目标"))
target_opt:value("", translate("仅创建规则，不绑定"))
target_opt:value(
    "socks_round_robin",
    translate("循环绑定SOCKS5")
)
target_opt:value("_direct", translate("直连"))
target_opt:value("_default", translate("使用默认节点"))
target_opt:value("_blackhole", translate("黑洞（阻断）"))
target_opt.default = #socks_nodes > 0 and "socks_round_robin" or "_direct"

local remarks_opt = s:option(Value, "remarks", translate("备注"))
remarks_opt.placeholder = translate("留空自动生成")

local group_opt = s:option(Value, "group", translate("分流规则组"))
group_opt.placeholder = translate("默认")

local network_opt = s:option(ListValue, "network", translate("网络"))
network_opt:value("tcp,udp", "TCP UDP")
network_opt:value("tcp", "TCP")
network_opt:value("udp", "UDP")
network_opt.default = "tcp,udp"

local source_opt = s:option(TextValue, "source", translate("内网 IP / CIDR"))
source_opt.rows = 18
source_opt.wrap = "off"
source_opt.rmempty = true
source_opt.description = translate(
    "示例：192.168.1.100、192.168.1.0/24、fd00::/8、geoip:private。" ..
    "支持逗号、空格或换行分隔；以 # 开头的行会被忽略。"
)

local overwrite_opt =
    s:option(Flag, "overwrite", translate("IP新增覆盖"))
overwrite_opt.description = translate(
    "启用后，已存在的单 IP 独立规则会更新网络、规则组和当前分流节点绑定；" ..
    "规则 ID 与备注保持不变。"
)
end

if mode == "delete" then
local source_keys = {}
local source_values = {}
uci:foreach("passwall", "shunt_rules", function(rule)
    local raw = rule.source
    local values = {}
    if type(raw) == "table" then
        values = raw
    elseif type(raw) == "string" then
        for value in raw:gmatch("%S+") do
            values[#values + 1] = value
        end
    end
    for _, value in ipairs(values) do
        local key = tostring(value):lower()
        if not source_keys[key] then
            source_keys[key] = true
            source_values[#source_values + 1] = tostring(value)
        end
    end
end)
table.sort(source_values)

local select_opt = s:option(DummyValue, "delete_select", translate("删除快速选择"))
select_opt.rawhtml = true
select_opt.default = [=[
<div style="display:flex;align-items:center;gap:1em;flex-wrap:wrap">
    <label style="display:inline-flex;align-items:center;gap:.4em;cursor:pointer">
        <input id="lan-batch-select-all" type="checkbox" class="cbi-input-checkbox"
            onclick="var on=this.checked;(function(on){var a=document.querySelectorAll('input.lan-ip-delete-box');for(var i=0;i<a.length;i++){if(a[i].checked!==on)a[i].click()}})(on);" />
        <span>全部选择</span>
    </label>
    <button type="button" class="cbi-button cbi-button-reset"
        onclick="document.getElementById('lan-batch-select-all').checked=false;(function(){var a=document.querySelectorAll('input.lan-ip-delete-box');for(var i=0;i<a.length;i++){if(a[i].checked)a[i].click()}})();return false;">
        全部取消选择
    </button>
</div>
]=]

local delete_sources_opt = s:option(
    MultiValue, "delete_sources", translate("已添加的内网 IP / CIDR")
)
delete_sources_opt.widget = "checkbox"
for _, value in ipairs(source_values) do
    delete_sources_opt:value(value, value)
end

local function html_escape(value)
    return tostring(value or "")
        :gsub("&", "&amp;")
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
end

local grid_items = {}
for _, value in ipairs(source_values) do
    local safe = html_escape(value)
    grid_items[#grid_items + 1] =
        '<label style="display:inline-flex;align-items:center;gap:.35em;' ..
        'white-space:nowrap;min-width:0;cursor:pointer;line-height:1.4;' ..
        'vertical-align:middle">' ..
        '<input class="lan-ip-delete-box" type="checkbox" ' ..
        'name="cbid.lan_batch.1.delete_sources" value="' .. safe ..
        '" style="margin:0;flex:0 0 auto;vertical-align:middle;' ..
        'position:relative;top:0;bottom:auto">' ..
        '<span style="line-height:1.4;vertical-align:middle">' ..
        safe .. '</span></label>'
end

local grid_opt = s:option(
    DummyValue, "delete_grid",
    translate("已添加的内网 IP / CIDR（每行 10 个）")
)
grid_opt.rawhtml = true
grid_opt.default =
    '<style>#cbi-lan_batch-1-delete_sources{display:none}</style>' ..
    '<div id="lan-ip-delete-grid" style="display:grid!important;' ..
    'grid-template-columns:repeat(10,max-content);' ..
    'justify-content:start;justify-items:start;' ..
    'row-gap:.45em;column-gap:.75em;align-items:center;' ..
    'flex:none!important">' ..
    table.concat(grid_items) .. '</div>'

local delete_confirm_opt =
    s:option(Flag, "delete_confirm", translate("确认删除所选内网 IP"))
end

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

local function valid_source(value)
    if value:match("^geoip:[%w_%-%.]+$") then
        return true
    end

    local datatypes = api.datatypes or {}
    for _, name in ipairs({ "ip4addr", "ipmask4", "ip6addr", "ipmask6" }) do
        local checker = datatypes[name]
        if type(checker) == "function" then
            local ok, result = pcall(checker, value)
            if ok and result then
                return true
            end
        end
    end

    local a, b, c, d, prefix =
        value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
    if not a then
        a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        prefix = "32"
    end
    if a then
        return tonumber(prefix) <= 32 and
            tonumber(a) <= 255 and tonumber(b) <= 255 and
            tonumber(c) <= 255 and tonumber(d) <= 255
    end

    if value:find(":", 1, true) then
        local address, bits = value:match("^([%x:]+)/(%d+)$")
        if not address then
            address = value
        elseif tonumber(bits) > 128 then
            return false
        end
        return address:match("^[%x:]+$") ~= nil
    end
    return false
end

local function selected_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            result[#result + 1] = tostring(item)
        end
    elseif type(value) == "string" then
        for item in value:gmatch("%S+") do
            result[#result + 1] = item
        end
    end
    return result
end

local function delete_sources(self, data)
    if data.delete_confirm ~= "1" then
        m.message = translate("请先勾选“确认删除所选内网 IP”。")
        return true
    end

    local selected = {}
    for _, value in ipairs(selected_list(data.delete_sources)) do
        selected[value:lower()] = true
    end
    if next(selected) == nil then
        m.message = translate("没有勾选有效的内网 IP。")
        return true
    end

    local pending = {}
    uci:foreach("passwall", "shunt_rules", function(rule)
        local raw = rule.source
        local values = {}
        if type(raw) == "table" then
            values = raw
        elseif type(raw) == "string" then
            for value in raw:gmatch("%S+") do
                values[#values + 1] = value
            end
        end

        local remaining = {}
        local matched = 0
        for _, value in ipairs(values) do
            if selected[tostring(value):lower()] then
                matched = matched + 1
            else
                remaining[#remaining + 1] = value
            end
        end
        if matched > 0 then
            pending[#pending + 1] = {
                id = rule[".name"],
                remaining = remaining,
                matched = matched
            }
        end
    end)

    if #pending == 0 then
        m.message = translate("没有找到匹配的内网 IP 分流规则。")
        return true
    end

    local sys = require("luci.sys")
    local backup = "/root/passwall.bak.landelete." ..
        os.date("%Y%m%d-%H%M%S")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        m.message = translate("备份 PassWall 配置失败，本次未删除。")
        return true
    end

    local shunt_ids = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "_shunt" then
            shunt_ids[#shunt_ids + 1] = node[".name"]
        end
    end)

    local removed_sources, deleted_rules, updated_rules, removed_bindings =
        0, 0, 0, 0
    for _, item in ipairs(pending) do
        removed_sources = removed_sources + item.matched
        if #item.remaining == 0 then
            for _, shunt_id in ipairs(shunt_ids) do
                local options = uci:get_all("passwall", shunt_id) or {}
                if options[item.id] ~= nil then
                    uci:delete("passwall", shunt_id, item.id)
                    removed_bindings = removed_bindings + 1
                end
            end
            uci:delete("passwall", item.id)
            deleted_rules = deleted_rules + 1
        else
            uci:set(
                "passwall", item.id, "source",
                table.concat(item.remaining, " ")
            )
            updated_rules = updated_rules + 1
        end
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，本次删除已撤销。")
        return true
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    m.message = string.format(
        translate(
            "删除完成：移除 %d 个来源，删除 %d 条空规则，" ..
            "更新 %d 条规则，移除 %d 个绑定。"
        ),
        removed_sources, deleted_rules, updated_rules, removed_bindings
    )
    return true
end

function m.handle(self, state, data)
    if state ~= FORM_VALID then
        return true
    end

    if mode == "delete" then
        return delete_sources(self, data)
    end

    local items = {}
    local seen = {}
    local overwrite = data.overwrite == "1"
    local duplicate, invalid = 0, 0

    uci:foreach("passwall", "shunt_rules", function(rule)
        local source = rule.source
        local values = {}
        if type(source) == "table" then
            values = source
        elseif type(source) == "string" then
            for value in source:gmatch("%S+") do
                values[#values + 1] = value
            end
        end
        for _, value in ipairs(values) do
            local key = tostring(value):lower()
            if not seen[key] then
                seen[key] = {
                    id = rule[".name"],
                    single = #values == 1
                }
            end
        end
    end)

    local raw = tostring(data.source or "")
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("#.*$", ""))
        for value in line:gmatch("[^,%s]+") do
            if #items >= 5000 then
                m.message = translate("单次最多导入 5000 个内网 IP，本次未写入。")
                return true
            end
            if not valid_source(value) then
                invalid = invalid + 1
            else
                local key = value:lower()
                local existing = seen[key]
                if existing then
                    if overwrite and existing.id and existing.single then
                        items[#items + 1] = {
                            source = value,
                            id = existing.id,
                            existing = true
                        }
                    else
                        duplicate = duplicate + 1
                    end
                else
                    seen[key] = { single = true }
                    items[#items + 1] = {
                        source = value,
                        existing = false
                    }
                end
            end
        end
    end

    if #items == 0 then
        m.message = string.format(
            translate("没有可导入的新来源：重复 %d 个，格式错误 %d 个。"),
            duplicate, invalid
        )
        return true
    end

    local network = data.network or "tcp,udp"
    if network ~= "tcp,udp" and network ~= "tcp" and network ~= "udp" then
        m.message = translate("网络类型无效。")
        return true
    end

    local target = data.target or ""
    if not (target == "" or target == "_direct" or
        target == "_default" or target == "_blackhole" or
        target == "socks_round_robin") then
        m.message = translate("绑定目标无效。")
        return true
    end

    local node_id = data.shunt_node or ""
    local node_found = false
    local node_group = ""
    uci:foreach("passwall", "nodes", function(node)
        if node[".name"] == node_id and node.protocol == "_shunt" then
            node_found = true
            node_group = trim(node.shunt_group)
        end
    end)
    if target ~= "" and not node_found then
        m.message = translate("没有找到可绑定的 Sing-Box/Xray 分流节点。")
        return true
    end

    local round_robin_nodes = {}
    if target == "socks_round_robin" then
        uci:foreach("passwall", "nodes", function(node)
            if node.protocol == "socks" then
                round_robin_nodes[#round_robin_nodes + 1] = node[".name"]
            end
        end)
        table.sort(round_robin_nodes)
        if #round_robin_nodes == 0 then
            m.message = translate("没有找到已导入的 SOCKS5 节点。")
            return true
        end
    end

    local group = trim(data.group)
    if target ~= "" then
        group = node_group
    end

    local base = os.time()
    local serial = 0
    local imported, overwritten = 0, 0
    local base_remarks = trim(data.remarks)
    if base_remarks == "" then
        base_remarks = "LAN-BATCH-" .. os.date("%Y%m%d-%H%M%S")
    end

    for index, item in ipairs(items) do
        local rule_id = item.id
        if item.existing then
            uci:set("passwall", rule_id, "network", network)
            uci:set("passwall", rule_id, "source", item.source)
            if group ~= "" then
                uci:set("passwall", rule_id, "group", group)
            else
                uci:delete("passwall", rule_id, "group")
            end
            overwritten = overwritten + 1
        else
            repeat
                serial = serial + 1
                rule_id = string.format("lan_batch_%d_%d", base, serial)
            until not uci:get("passwall", rule_id)

            local values = {
                remarks = string.format("%s-%03d", base_remarks, index),
                network = network,
                source = item.source
            }
            if group ~= "" then
                values.group = group
            end

            if not uci:section(
                "passwall", "shunt_rules", rule_id, values
            ) then
                uci:revert("passwall")
                m.message = translate(
                    "写入分流规则失败，本次导入已撤销。"
                )
                return true
            end
            imported = imported + 1
        end

        local binding_target = target
        if target == "socks_round_robin" then
            local node_index =
                ((index - 1) % #round_robin_nodes) + 1
            binding_target = round_robin_nodes[node_index]
        end
        if binding_target ~= "" and
            not uci:set(
                "passwall", node_id, rule_id, binding_target
            ) then
            uci:revert("passwall")
            m.message = translate("绑定分流目标失败，本次导入已撤销。")
            return true
        end
    end

    if target ~= "" then
        uci:set("passwall", "@global[0]", "node", node_id)
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，本次导入已撤销。")
        return true
    end

    require("luci.sys").call(
        "(/etc/init.d/passwall restart >/dev/null 2>&1 &)"
    )
    m.message = string.format(
        translate(
            "导入完成：新增 %d 条，覆盖 %d 条，" ..
            "重复跳过 %d 个，格式错误 %d 个。规则前缀：%s"
        ),
        imported, overwritten, duplicate, invalid, base_remarks
    )
    if target == "socks_round_robin" then
        m.message = m.message .. string.format(
            translate(" 已循环绑定到 %d 个 SOCKS5 节点。"),
            #round_robin_nodes
        )
    end
    local active_node = uci:get("passwall", "@global[0]", "node") or ""
    if target ~= "" and active_node ~= node_id then
        m.message = m.message .. translate(
            " 当前 PassWall 未使用所选分流节点，请切换到该节点后生效。"
        )
    end
    return true
end

if type(api.return_map) == "function" then
    return api.return_map(m)
end
return m
EOF

cat >"$tmp_dir/lan_delete.lua" <<'EOF'
local api = require "luci.passwall.api"
if type(api.set_default_cbi) == "function" then
    api.set_default_cbi()
end

local uci = require "luci.model.uci".cursor()
local m = SimpleForm("lan_delete", translate("内网IP分流批量删除"))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate("批量删除")
m.description = translate(
    "按来源 IP/CIDR 精确删除所有 Sing-Box/Xray 分流规则中的对应项。" ..
    "规则没有其他来源时会一并删除，并从所有分流节点移除绑定。"
)

local s = m:section(SimpleSection)

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

local function source_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            result[#result + 1] = tostring(item)
        end
    elseif type(value) == "string" then
        for item in value:gmatch("%S+") do
            result[#result + 1] = item
        end
    end
    return result
end

local source_map = {}
local source_values = {}
uci:foreach("passwall", "shunt_rules", function(rule)
    for _, value in ipairs(source_list(rule.source)) do
        local key = value:lower()
        if not source_map[key] then
            source_map[key] = { value = value, count = 0 }
            source_values[#source_values + 1] = source_map[key]
        end
        source_map[key].count = source_map[key].count + 1
    end
end)
table.sort(source_values, function(a, b)
    return a.value < b.value
end)

local select_opt = s:option(DummyValue, "quick_select", translate("快速选择"))
select_opt.rawhtml = true
select_opt.default = [=[
<div style="display:flex;align-items:center;gap:1em;flex-wrap:wrap">
    <label style="display:inline-flex;align-items:center;gap:.4em;cursor:pointer">
        <input id="lan-delete-select-all" type="checkbox" class="cbi-input-checkbox"
            onclick="var on=this.checked;(function(on){var r=document.getElementById('cbid.lan_delete.1.sources');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.lan_delete.1.sources&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked!==on)a[i].click()}})(on);" />
        <span>全部选择</span>
    </label>
    <button type="button" class="cbi-button cbi-button-reset"
        onclick="document.getElementById('lan-delete-select-all').checked=false;(function(){var r=document.getElementById('cbid.lan_delete.1.sources');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.lan_delete.1.sources&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked)a[i].click()}})();return false;">
        全部取消选择
    </button>
</div>
]=]

local source_opt = s:option(
    MultiValue, "sources", translate("已添加的内网 IP / CIDR")
)
source_opt.widget = "checkbox"
source_opt.rmempty = false
source_opt.description = translate(
    "勾选要删除的来源。同一来源出现在多条规则中时会一并处理。"
)
for _, item in ipairs(source_values) do
    local label = item.value
    if item.count > 1 then
        label = label .. string.format(" (%d)", item.count)
    end
    source_opt:value(item.value, label)
end

local confirm_opt = s:option(Flag, "confirm", translate("确认执行批量删除"))
confirm_opt.rmempty = false

function m.handle(self, state, data)
    if state ~= FORM_VALID then
        return true
    end

    if data.confirm ~= "1" then
        m.message = translate("请先勾选“确认执行批量删除”。")
        return true
    end

    local requested = {}
    local order = {}
    local selected = source_list(data.sources)
    for _, value in ipairs(selected) do
        value = trim(value)
        local key = value:lower()
        if value ~= "" and not requested[key] then
            requested[key] = value
            order[#order + 1] = key
        end
    end

    if #order == 0 then
        m.message = translate("没有填写要删除的 IP/CIDR。")
        return true
    end

    local found = {}
    local pending = {}
    uci:foreach("passwall", "shunt_rules", function(rule)
        local values = source_list(rule.source)
        local remaining = {}
        local matched = 0
        for _, value in ipairs(values) do
            local key = value:lower()
            if requested[key] then
                matched = matched + 1
                found[key] = true
            else
                remaining[#remaining + 1] = value
            end
        end
        if matched > 0 then
            pending[#pending + 1] = {
                id = rule[".name"],
                remaining = remaining,
                matched = matched
            }
        end
    end)

    if #pending == 0 then
        m.message = translate("没有找到匹配的分流来源，未修改配置。")
        return true
    end

    local removed_sources, deleted_rules, updated_rules, removed_bindings = 0, 0, 0, 0
    for _, item in ipairs(pending) do
        removed_sources = removed_sources + item.matched
        if #item.remaining == 0 then
            uci:delete("passwall", item.id)
            deleted_rules = deleted_rules + 1
            uci:foreach("passwall", "nodes", function(node)
                if node.protocol == "_shunt" and
                    uci:get("passwall", node[".name"], item.id) ~= nil then
                    uci:delete("passwall", node[".name"], item.id)
                    removed_bindings = removed_bindings + 1
                end
            end)
        else
            uci:set(
                "passwall", item.id, "source",
                table.concat(item.remaining, " ")
            )
            updated_rules = updated_rules + 1
        end
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，本次删除已撤销。")
        return true
    end

    require("luci.sys").call(
        "(/etc/init.d/passwall restart >/dev/null 2>&1 &)"
    )
    local not_found = 0
    for _, key in ipairs(order) do
        if not found[key] then
            not_found = not_found + 1
        end
    end
    m.message = string.format(
        translate(
            "删除完成：移除 %d 个来源，删除 %d 条空规则，更新 %d 条规则，" ..
            "移除 %d 个绑定；未找到 %d 个来源。"
        ),
        removed_sources, deleted_rules, updated_rules,
        removed_bindings, not_found
    )
    return true
end

if type(api.return_map) == "function" then
    return api.return_map(m)
end
return m
EOF

cat >"$tmp_dir/socks_delete.lua" <<'EOF'
local api = require "luci.passwall.api"
if type(api.set_default_cbi) == "function" then
    api.set_default_cbi()
end

local uci = require "luci.model.uci".cursor()
local m = SimpleForm("socks_delete", translate("SK5 节点批量删除"))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate("删除所选 SK5")
m.description = translate(
    "勾选要删除的 SOCKS5 节点。删除时同步清理分流节点中的绑定；" ..
    "内网 IP 分流规则本身保留。"
)

local s = m:section(SimpleSection)

local function socks_nodes()
    local result = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "socks" then
            result[#result + 1] = {
                id = node[".name"],
                remarks = node.remarks or node[".name"],
                address = node.address or "",
                port = node.port or ""
            }
        end
    end)
    table.sort(result, function(a, b)
        if a.remarks == b.remarks then
            return a.id < b.id
        end
        return a.remarks < b.remarks
    end)
    return result
end

local nodes = socks_nodes()

local select_opt = s:option(DummyValue, "quick_select", translate("快速选择"))
select_opt.rawhtml = true
select_opt.default = [=[
<div style="display:flex;align-items:center;gap:1em;flex-wrap:wrap">
    <label style="display:inline-flex;align-items:center;gap:.4em;cursor:pointer">
        <input id="socks-delete-select-all" type="checkbox" class="cbi-input-checkbox"
            onclick="var on=this.checked;(function(on){var r=document.getElementById('cbid.socks_delete.1.nodes');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.socks_delete.1.nodes&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked!==on)a[i].click()}})(on);" />
        <span>全部选择</span>
    </label>
    <button type="button" class="cbi-button cbi-button-reset"
        onclick="document.getElementById('socks-delete-select-all').checked=false;(function(){var r=document.getElementById('cbid.socks_delete.1.nodes');if(!r)return;var a=r.querySelectorAll('input[type=checkbox][name=&quot;cbid.socks_delete.1.nodes&quot;]');for(var i=0;i<a.length;i++){if(a[i].checked)a[i].click()}})();return false;">
        全部取消选择
    </button>
</div>
]=]

local node_opt = s:option(
    MultiValue, "nodes", translate("已导入的 SOCKS5 节点")
)
node_opt.widget = "checkbox"
node_opt.rmempty = false
for _, node in ipairs(nodes) do
    node_opt:value(
        node.id,
        string.format("%s | %s:%s", node.remarks, node.address, node.port)
    )
end

local confirm_opt = s:option(Flag, "confirm", translate("确认删除所选 SK5"))
confirm_opt.rmempty = false

local function selected_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            result[#result + 1] = tostring(item)
        end
    elseif type(value) == "string" then
        for item in value:gmatch("%S+") do
            result[#result + 1] = item
        end
    end
    return result
end

function m.handle(self, state, data)
    if state ~= FORM_VALID then
        return true
    end

    if data.confirm ~= "1" then
        m.message = translate("请先勾选“确认删除所选 SK5”。")
        return true
    end

    local current_nodes = socks_nodes()
    local known = {}
    for _, node in ipairs(current_nodes) do
        known[node.id] = node
    end

    local selected = {}
    local selected_ids = {}
    for _, id in ipairs(selected_list(data.nodes)) do
        if known[id] and not selected[id] then
            selected[id] = true
            selected_ids[#selected_ids + 1] = id
        end
    end
    if #selected_ids == 0 then
        m.message = translate("没有勾选有效的 SK5 节点。")
        return true
    end

    local remaining = {}
    for _, node in ipairs(current_nodes) do
        if not selected[node.id] then
            remaining[#remaining + 1] = node
        end
    end

    local shunt_ids = {}
    uci:foreach("passwall", "nodes", function(node)
        if node.protocol == "_shunt" then
            shunt_ids[#shunt_ids + 1] = node[".name"]
        end
    end)

    local backup = "/root/passwall.bak.skdelete." ..
        os.date("%Y%m%d-%H%M%S")
    local sys = require("luci.sys")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        m.message = translate("备份 PassWall 配置失败，本次未删除。")
        return true
    end

    local removed_bindings, updated_defaults, defaults_reset = 0, 0, 0
    for _, shunt_id in ipairs(shunt_ids) do
        local options = uci:get_all("passwall", shunt_id) or {}
        for option, value in pairs(options) do
            if option ~= "default_node" and
                type(value) == "string" and selected[value] then
                uci:delete("passwall", shunt_id, option)
                removed_bindings = removed_bindings + 1
            end
        end

        local default_node =
            uci:get("passwall", shunt_id, "default_node")
        if default_node and selected[default_node] then
            if remaining[1] then
                uci:set(
                    "passwall", shunt_id, "default_node",
                    remaining[1].id
                )
                updated_defaults = updated_defaults + 1
            else
                uci:delete("passwall", shunt_id, "default_node")
                defaults_reset = defaults_reset + 1
            end
        end
    end

    local active_node = uci:get("passwall", "@global[0]", "node")
    if active_node and selected[active_node] then
        if remaining[1] then
            uci:set(
                "passwall", "@global[0]", "node",
                remaining[1].id
            )
        elseif shunt_ids[1] then
            uci:set(
                "passwall", "@global[0]", "node",
                shunt_ids[1]
            )
        else
            uci:delete("passwall", "@global[0]", "node")
        end
    end

    for _, id in ipairs(selected_ids) do
        uci:delete("passwall", id)
    end

    local saved = false
    if type(api.uci_save) == "function" then
        local ok, result =
            pcall(api.uci_save, uci, "passwall", true, true)
        saved = ok and result ~= false
    else
        saved = uci:commit("passwall")
    end
    if not saved then
        uci:revert("passwall")
        m.message = translate("配置提交失败，节点删除已撤销。")
        return true
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    m.message = string.format(
        translate(
            "删除完成：节点 %d 个，清理规则绑定 %d 个，" ..
            "更新默认出口 %d 个，重置默认出口 %d 个。"
        ),
        #selected_ids, removed_bindings,
        updated_defaults, defaults_reset
    )
    return true
end

if type(api.return_map) == "function" then
    return api.return_map(m)
end
return m
EOF

cat >"$tmp_dir/check.lua" <<EOF
assert(loadfile("$tmp_dir/controller.lua"))
assert(loadfile("$tmp_dir/model.lua"))
assert(loadfile("$tmp_dir/lan_model.lua"))
assert(loadfile("$tmp_dir/lan_delete.lua"))
assert(loadfile("$tmp_dir/socks_delete.lua"))
EOF
lua "$tmp_dir/check.lua" || fail "Lua 语法检查失败"

mkdir -p "$(dirname "$CONTROLLER")" "$(dirname "$MODEL")" "$(dirname "$LAN_MODEL")"
[ ! -f "$CONTROLLER" ] || cp -p "$CONTROLLER" "$CONTROLLER.bak.$stamp"
[ ! -f "$MODEL" ] || cp -p "$MODEL" "$MODEL.bak.$stamp"
[ ! -f "$LAN_MODEL" ] || cp -p "$LAN_MODEL" "$LAN_MODEL.bak.$stamp"
[ ! -f "$LAN_DELETE" ] || cp -p "$LAN_DELETE" "$LAN_DELETE.bak.$stamp"
[ ! -f "$SOCKS_DELETE" ] || cp -p "$SOCKS_DELETE" "$SOCKS_DELETE.bak.$stamp"
rm -f "$LAN_DELETE" "$SOCKS_DELETE"

mv "$tmp_dir/controller.lua" "$CONTROLLER"
mv "$tmp_dir/model.lua" "$MODEL"
mv "$tmp_dir/lan_model.lua" "$LAN_MODEL"
chmod 644 "$CONTROLLER" "$MODEL" "$LAN_MODEL"
fix_xray_source_rules
fix_sk5 "223.5.5.5"
clear_luci_cache

echo "安装完成。"
echo "打开：服务 -> PassWall -> SOCKS5 批量导入"
echo "打开：服务 -> PassWall -> 内网IP导入"
echo "如果页面未出现，请刷新浏览器或重新登录 LuCI。"
