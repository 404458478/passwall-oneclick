#!/bin/sh
set -eu

CONTROLLER="/usr/lib/lua/luci/controller/passwall_socks_batch.lua"
MODEL="/usr/lib/lua/luci/model/cbi/passwall/client/socks_batch.lua"
LAN_MODEL="/usr/lib/lua/luci/model/cbi/passwall/client/lan_batch.lua"
LAN_DELETE="/usr/lib/lua/luci/model/cbi/passwall/client/lan_delete.lua"
SOCKS_DELETE="/usr/lib/lua/luci/model/cbi/passwall/client/socks_delete.lua"
XRAY_UTIL="/usr/lib/lua/luci/passwall/util_xray.lua"
TOP_NODE_LIST="/usr/lib/lua/luci/view/passwall/node_list/node_list.htm"
PASSWALL_NFTABLES="/usr/share/passwall/nftables.sh"
SINGBOX_UTIL="/usr/lib/lua/luci/passwall/util_sing-box.lua"
ASSET_BASE="https://raw.githubusercontent.com/404458478/passwall-oneclick/main/assets"

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

install_asset() {
    name="$1"
    target="$2"
    mode="$3"
    stamp="$4"
    script_dir="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
    source_file="$script_dir/assets/$name"
    tmp_file="/tmp/$name.oneclick.$$"

    if [ -f "$source_file" ]; then
        cp "$source_file" "$tmp_file"
    else
        command -v curl >/dev/null 2>&1 ||
            fail "未找到 curl，无法下载 $name"
        curl -fsSL "$ASSET_BASE/$name" -o "$tmp_file" ||
            fail "下载失败：$name"
    fi

    [ -s "$tmp_file" ] || fail "文件内容为空：$name"
    mkdir -p "$(dirname "$target")"
    [ ! -f "$target" ] ||
        cp -p "$target" "$target.bak.oneclick.$stamp"
    cp "$tmp_file" "$target"
    chmod "$mode" "$target"
    rm -f "$tmp_file"
}

install_runtime_assets() {
    stamp="$1"
    install_asset "passwall-node-list.htm" "$TOP_NODE_LIST" 644 "$stamp"
    install_asset "passwall-nftables.sh" "$PASSWALL_NFTABLES" 755 "$stamp"
    install_asset "passwall-util_sing-box.lua" "$SINGBOX_UTIL" 644 "$stamp"
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
    uci set passwall.@global[0].tcp_proxy_way='redirect'
    uci set passwall.@global_forwarding[0].tcp_proxy_way='redirect'
    uci set passwall.@global_forwarding[0].prefer_nft='1'
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
    [ "$(uci -q get passwall.@global_forwarding[0].tcp_proxy_way)" = "redirect" ] ||
        fail "TCP 转发方式设置失败"
    [ "$(uci -q get passwall.@global[0].udp_proxy_mode)" = "proxy" ] ||
        fail "UDP 全局代理设置失败"
    [ "$(uci -q get passwall.@global[0].direct_dns)" = "$dns" ] ||
        fail "直连 DNS 设置失败"
    [ "$(uci -q get passwall.@global[0].remote_dns)" = "$dns" ] ||
        fail "远程 DNS 设置失败"

    /etc/init.d/passwall restart

    echo "SOCKS5 全局 TCP/UDP 代理模式已启用。"
    echo "DNS：$dns（TCP）"
    echo "TCP/UDP：全局经过 SOCKS5"
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
PassWall 节点管理扩展安装脚本

用法：
  sh passwall-socks5-batch.sh             安装或更新
  sh passwall-socks5-batch.sh --uninstall 卸载导入页面
  sh passwall-socks5-batch.sh --fix-sk5 [DNS]
                                          修复 SOCKS5 的 DNS 和 UDP 兼容性
                                          默认 DNS：223.5.5.5

安装后进入：
  服务 -> PassWall -> 节点管理
  服务 -> PassWall -> 批量导入分流规则
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
    }, firstchild(), "节点管理", 4)
    socks_entry.dependent = true
    socks_entry.acl_depends = { "luci-app-passwall" }

    local socks_import = entry({
        "admin", "services", api.appname, "socks_batch", "import"
    }, form(api.appname .. "/client/socks_batch"), "批量导入节点", 1)
    socks_import.leaf = true
    socks_import.acl_depends = { "luci-app-passwall" }

    local quick_edit = entry({
        "admin", "services", api.appname, "socks_quick_edit"
    }, call("socks_quick_edit"))
    quick_edit.leaf = true
    quick_edit.acl_depends = { "luci-app-passwall" }

    local block_direct = entry({
        "admin", "services", api.appname, "socks_block_direct"
    }, call("socks_block_direct"))
    block_direct.leaf = true
    block_direct.acl_depends = { "luci-app-passwall" }

    local lan_entry = entry({
        "admin", "services", api.appname, "lan_batch"
    }, form(api.appname .. "/client/lan_batch"), "批量导入分流规则", 5)
    lan_entry.leaf = true
    lan_entry.acl_depends = { "luci-app-passwall" }

end

local function reply_json(data, status)
    local http = require "luci.http"
    local json = require "luci.jsonc"
    http.status(status or 200)
    http.prepare_content("application/json")
    http.write(json.stringify(data or {}) or "{}")
end

local function clean(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function socks_quick_edit()
    local http = require "luci.http"
    local id = clean(http.formvalue("id"))
    if id == "" or not id:match("^[%w_%-]+$") then
        return reply_json({
            success = false,
            message = "节点 ID 无效。"
        }, 400)
    end

    local uci = require("luci.model.uci").cursor()
    local node = uci:get_all("passwall", id)
    if not node or node.protocol ~= "socks" then
        return reply_json({
            success = false,
            message = "未找到 SOCKS5 节点。"
        }, 404)
    end

    if http.getenv("REQUEST_METHOD") ~= "POST" then
        return reply_json({
            success = true,
            id = id,
            remarks = node.remarks or id,
            address = node.address or "",
            port = node.port or "",
            username = node.username or ""
        })
    end

    local remarks = clean(http.formvalue("remarks"))
    local address = clean(http.formvalue("address"))
    local port = tonumber(clean(http.formvalue("port")))
    local username = tostring(http.formvalue("username") or "")
    local password = tostring(http.formvalue("password") or "")

    if remarks == "" then
        remarks = id
    elseif #remarks > 255 then
        return reply_json({
            success = false,
            message = "备注不能超过 255 个字符。"
        }, 400)
    end
    if address == "" or #address > 253 or address:find("%s") then
        return reply_json({
            success = false,
            message = "节点地址无效。"
        }, 400)
    end
    if not port or port < 1 or port > 65535 then
        return reply_json({
            success = false,
            message = "节点端口无效。"
        }, 400)
    end

    local sys = require "luci.sys"
    local backup = "/root/passwall.bak.quickedit." ..
        os.date("%Y%m%d-%H%M%S")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        return reply_json({
            success = false,
            message = "备份 PassWall 配置失败，本次未修改。"
        }, 500)
    end

    uci:set("passwall", id, "remarks", remarks)
    uci:set("passwall", id, "address", address)
    uci:set("passwall", id, "port", tostring(port))
    uci:set("passwall", id, "username", username)
    if password ~= "" then
        uci:set("passwall", id, "password", password)
    end

    if not uci:commit("passwall") then
        uci:revert("passwall")
        return reply_json({
            success = false,
            message = "保存失败，修改已撤销。"
        }, 500)
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    reply_json({
        success = true,
        message = "SOCKS5 节点已保存。",
        id = id
    })
end

function socks_block_direct()
    local http = require "luci.http"
    local uci = require("luci.model.uci").cursor()
    local section = "@global_other[0]"
    local enabled =
        uci:get("passwall", section, "block_direct_on_socks_failure") == "1"

    if http.getenv("REQUEST_METHOD") ~= "POST" then
        return reply_json({
            success = true,
            enabled = enabled
        })
    end

    local want = http.formvalue("enabled") == "1"
    if want == enabled then
        return reply_json({
            success = true,
            enabled = enabled
        })
    end

    local sys = require "luci.sys"
    local backup = "/root/passwall.bak.blockdirect." ..
        os.date("%Y%m%d-%H%M%S")
    if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
        return reply_json({
            success = false,
            message = "备份 PassWall 配置失败，本次未修改。"
        }, 500)
    end

    if want then
        local defaults = {}
        uci:foreach("passwall", "nodes", function(node)
            if node.protocol == "_shunt" then
                defaults[node[".name"]] =
                    node.default_node or ""
                uci:set(
                    "passwall", node[".name"],
                    "default_node", "_blackhole"
                )
            end
        end)
        uci:set(
            "passwall", section,
            "block_direct_defaults",
            require("luci.jsonc").stringify(defaults)
        )
        uci:set(
            "passwall", section,
            "block_direct_on_socks_failure", "1"
        )
    else
        local defaults = {}
        local ok = pcall(function()
            defaults = require("luci.jsonc").parse(
                uci:get(
                    "passwall", section,
                    "block_direct_defaults"
                ) or "{}"
            ) or {}
        end)
        if ok then
            for id, target in pairs(defaults) do
                local node = uci:get_all("passwall", id)
                if node and node.protocol == "_shunt" then
                    if target ~= "" then
                        uci:set(
                            "passwall", id,
                            "default_node", target
                        )
                    else
                        uci:delete(
                            "passwall", id, "default_node"
                        )
                    end
                end
            end
        end
        uci:delete(
            "passwall", section, "block_direct_defaults"
        )
        uci:delete(
            "passwall", section,
            "block_direct_on_socks_failure"
        )
    end

    if not uci:commit("passwall") then
        uci:revert("passwall")
        return reply_json({
            success = false,
            message = "保存失败，修改已撤销。"
        }, 500)
    end

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    reply_json({
        success = true,
        enabled = want
    })
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
    import = "批量导入节点",
    check = "SOCKS5 节点列表 / 测 IP",
    delete = "批量删除 SOCKS5"
}
local m = SimpleForm("socks_batch", translate(mode_titles[mode]))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate(
    mode == "check" and "一键测 IP / 可用性" or
    mode == "delete" and "删除所选 SOCKS5" or "导入"
)
if mode == "check" then
    m.description = translate(
        "节点默认全选。一键检测会显示实际出口 SOCKS5 IP、归属地和是否可用；" ..
        "不可用节点会高亮，并提供原位修改。"
    )
else
    m.description = translate(
        "勾选要删除的 SOCKS5 节点。删除时会同步清理分流节点中的绑定。"
    )
end

local s = m:section(SimpleSection)

if mode == "check" then
    local operation_opt =
        s:option(ListValue, "operation", translate("操作类型"))
    operation_opt:value(
        "check", translate("一键测 IP 并检测是否可用")
    )
    operation_opt:value("edit", translate("原位修改 SOCKS5 节点"))
    operation_opt.default = "check"
elseif mode == "import" then
local import_ui = s:option(
    DummyValue, "node_import_ui", translate("批量导入节点")
)
import_ui.rawhtml = true
import_ui.default = [=[
<style>
#cbi-socks_batch-1-node_import_ui { width:100% !important; padding:0 !important; }
#cbi-socks_batch-1-node_import_ui .cbi-value-title { display:none !important; }
#cbi-socks_batch-1-node_import_ui .cbi-value-field { width:100% !important; }
.cbi-map > h2, .cbi-map > .cbi-map-title,
.cbi-map h2:first-of-type { display:none !important; }
.pw-node-import {
    --pw-accent:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7)))));
    --pw-bg:var(--background-color, #fff);
    --pw-surface:var(--background-color-high,
        var(--background-color, #f4f4f4));
    --pw-text:var(--text-color, #333);
    --pw-muted:var(--text-color-medium, var(--text-color, #666));
    --pw-border:var(--border-color,
        var(--border-color-high, #d8dde3));
    background:var(--pw-bg);
    color:var(--pw-text);
    left:20px;
    margin:0 auto;
    max-width:900px;
    position:relative;
}
.pw-node-import-title {
    background:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7))))) !important;
    color:#fff;
    font-size:16px;
    font-weight:600;
    padding:8px 14px;
}
.pw-node-import-body { padding:18px 20px 20px; }
.pw-node-protocols {
    align-items:center;
    display:flex;
    flex-wrap:wrap;
    gap:20px;
    margin-bottom:16px;
}
.pw-node-protocols label {
    align-items:center;
    display:inline-flex !important;
    flex:0 0 auto;
    gap:7px;
    line-height:1.4;
    margin:0 !important;
    white-space:nowrap;
}
.pw-node-import .pw-node-protocols input[type="radio"] {
    accent-color:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7))))) !important;
    align-self:center !important;
    appearance:auto !important;
    -webkit-appearance:radio !important;
    flex:0 0 18px !important;
    height:18px !important;
    margin:0 !important;
    position:relative;
    top:1px;
    transform:none !important;
    vertical-align:middle !important;
    width:18px !important;
}
.pw-node-help {
    background:var(--pw-surface);
    color:var(--pw-muted);
    display:grid;
    font-size:14px;
    gap:12px;
    grid-template-columns:84px minmax(0, 1fr);
    line-height:1.7;
    margin-bottom:12px;
    padding:14px 18px;
}
.pw-node-help-examples {
    font-family:monospace;
    margin-top:2px;
    padding-left:16px;
}
.pw-node-import-text {
    box-sizing:border-box;
    min-height:300px;
    padding:8px 10px;
    resize:vertical;
    width:100%;
}
.pw-node-import-options {
    align-items:center;
    display:flex;
    flex-wrap:nowrap;
    gap:18px;
    justify-content:space-between;
    margin-top:10px;
    overflow-x:auto;
    padding-bottom:2px;
    white-space:nowrap;
}
.pw-node-import-options label {
    align-items:center;
    display:inline-flex !important;
    flex:0 0 auto;
    gap:6px;
    line-height:1.4;
    margin:0 !important;
}
.pw-node-import .pw-node-import-options input[type="checkbox"] {
    accent-color:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7))))) !important;
    align-self:center !important;
    appearance:auto !important;
    -webkit-appearance:checkbox !important;
    flex:0 0 18px !important;
    height:18px !important;
    margin:0 !important;
    position:relative;
    top:-3px;
    transform:none !important;
    vertical-align:middle !important;
    width:18px !important;
}
.pw-node-import .pw-node-import-options input#pw-node-start-index {
    box-sizing:border-box;
    display:inline-block !important;
    flex:0 0 40px !important;
    height:30px;
    margin:0 !important;
    max-width:40px !important;
    min-width:40px !important;
    padding:3px 5px !important;
    text-align:center;
    vertical-align:middle;
    width:40px !important;
}
.pw-node-import .pw-node-import-options input#pw-node-group-name {
    box-sizing:border-box;
    flex:0 0 150px;
    height:30px;
    margin:0 !important;
    padding:3px 7px !important;
    width:150px !important;
}
.pw-node-import-actions {
    display:flex;
    gap:18px;
    justify-content:center;
    margin-top:18px;
}
.pw-node-import-btn {
    border:0;
    border-radius:3px;
    cursor:pointer;
    min-width:100px;
    padding:7px 14px;
}
.pw-node-import-submit { background:var(--pw-accent); color:#fff; }
.pw-node-import-cancel {
    background:var(--pw-bg);
    border:1px solid var(--pw-border);
    color:var(--pw-text);
}
#pw-node-import-success-modal {
    align-items:center;
    background:color-mix(in srgb, var(--text-color, #000) 38%, transparent);
    display:none;
    inset:0;
    justify-content:center;
    padding:16px;
    position:fixed;
    z-index:2000;
}
#pw-node-import-success-modal.open { display:flex; }
#pw-node-import-success-dialog {
    background:var(--background-color, #fff);
    border:1px solid var(--border-color, #d8dde3);
    border-radius:6px;
    color:var(--text-color, #333);
    max-width:420px;
    padding:22px 24px 18px;
    text-align:center;
    width:100%;
}
#pw-node-import-success-title {
    font-size:18px;
    font-weight:600;
    margin-bottom:12px;
}
#pw-node-import-success-message {
    line-height:1.8;
    margin-bottom:18px;
    white-space:pre-line;
}
.pw-node-import-success-actions {
    display:flex;
    justify-content:center;
}
#pw-node-import-success-ok {
    background:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7))))) !important;
    border:0;
    border-radius:4px;
    color:#fff;
    cursor:pointer;
    min-width:96px;
    padding:7px 18px;
}
.cbi-page-actions { display:none !important; }
</style>
<div class="pw-node-import">
    <button id="pw-node-import-real-submit" type="submit" name="cbi.apply" value="1"
        style="display:none" aria-hidden="true"></button>
    <div class="pw-node-import-title">批量导入节点</div>
    <div class="pw-node-import-body">
        <div class="pw-node-protocols">
            <strong>选择节点类型：</strong>
            <label><input type="radio" name="import_type" value="socks5" checked/>Socks5</label>
        </div>
        <div class="pw-node-help">
            <div>帮助提示：</div>
            <div>
                请使用下面的格式，分隔符可在英文逗号（,）、斜线（/）、竖线（|）与冒号（:）中任选一种：
                <div class="pw-node-help-examples">
                    <div>110.110.110.111/1081/username/password/nodename1</div>
                    <div>110.110.110.112/1081/username/password/nodename2</div>
                    <div>110.110.110.113/1081/username/password/nodename3</div>
                </div>
            </div>
        </div>
        <textarea id="pw-node-import-text" class="pw-node-import-text cbi-input-textarea"
            name="nodes" wrap="off" placeholder="按上述格式在此输入要导入的节点列表"></textarea>
        <div class="pw-node-import-options">
            <label>
                <input id="pw-node-auto-name" type="checkbox" name="auto_name" value="1" checked/>
                自动生成节点名称（起始编号：
                <input id="pw-node-start-index" type="text" name="start_index"
                    inputmode="numeric" maxlength="9" value="1"
                    oninput="this.value=this.value.replace(/\D/g,'')"/>
                ）
            </label>
            <label>
                <input id="pw-node-use-group" type="checkbox" name="use_group" value="1"
                    onchange="document.getElementById('pw-node-group-name').disabled=!this.checked"/>
                指定节点分组
                <input id="pw-node-group-name" type="text" name="node_group" disabled/>
            </label>
            <label>
                <input id="pw-node-clear-existing" type="checkbox" name="clear_nodes" value="1"/>
                清空已有节点数据
            </label>
        </div>
        <div class="pw-node-import-actions">
            <button class="pw-node-import-btn pw-node-import-submit" type="button" onclick="pwNodeImportSubmit(this);return false;">导入</button>
            <button class="pw-node-import-btn pw-node-import-cancel" type="button" onclick="location.reload()">取消</button>
        </div>
    </div>
</div>
<div id="pw-node-import-success-modal" role="dialog" aria-modal="true" aria-labelledby="pw-node-import-success-title">
    <div id="pw-node-import-success-dialog">
        <div id="pw-node-import-success-title">导入成功</div>
        <div id="pw-node-import-success-message"></div>
        <div class="pw-node-import-success-actions">
            <button id="pw-node-import-success-ok" type="button"
                onclick="document.getElementById('pw-node-import-success-modal').classList.remove('open')">确定</button>
        </div>
    </div>
</div>
<script>
function pwCenteredDialog(message, options) {
    options = options || {};
    var overlay = document.createElement("div");
    overlay.style.cssText =
        "position:fixed;inset:0;z-index:3000;display:flex;" +
        "align-items:center;justify-content:center;padding:16px;" +
        "background:color-mix(in srgb,var(--text-color,#000) 38%,transparent);" +
        "box-sizing:border-box";
    var dialog = document.createElement("div");
    dialog.style.cssText =
        "width:100%;max-width:420px;background:var(--background-color,#fff);" +
        "color:var(--text-color,#333);border:1px solid " +
        "var(--border-color,#d8dde3);border-radius:6px;" +
        "padding:22px 24px 18px;text-align:center;" +
        "box-sizing:border-box";
    var title = document.createElement("div");
    title.textContent = options.title || "提示";
    title.style.cssText =
        "font-size:18px;font-weight:600;margin-bottom:12px";
    var body = document.createElement("div");
    body.textContent = String(message || "");
    body.style.cssText =
        "white-space:pre-line;line-height:1.8;margin-bottom:18px";
    var actions = document.createElement("div");
    actions.style.cssText =
        "display:flex;justify-content:center;gap:12px";
    function close() {
        if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
    }
    if (options.confirm) {
        var cancel = document.createElement("button");
        cancel.type = "button";
        cancel.textContent = "取消";
        cancel.style.cssText =
            "min-width:88px;padding:7px 16px;border:1px solid " +
            "var(--border-color,#d8dde3);border-radius:4px;" +
            "background:var(--background-color,#fff);" +
            "color:var(--text-color,#444);cursor:pointer";
        cancel.onclick = close;
        actions.appendChild(cancel);
    }
    var ok = document.createElement("button");
    ok.type = "button";
    ok.textContent = "确定";
    ok.style.cssText =
        "min-width:88px;padding:7px 16px;border:0;border-radius:4px;" +
        "background:var(--primary,var(--primary-color-high," +
        "var(--brand,var(--v-accent,var(--accent,#337ab7)))));" +
        "color:#fff;cursor:pointer";
    ok.onclick = function() {
        close();
        if (typeof options.onOk === "function") options.onOk();
    };
    actions.appendChild(ok);
    dialog.appendChild(title);
    dialog.appendChild(body);
    dialog.appendChild(actions);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
}

function pwNodeImportSubmit(button) {
    var text = document.getElementById("pw-node-import-text").value.trim();
    if (!text) {
        pwCenteredDialog("请先输入要导入的节点列表。");
        return;
    }
    function submitForm() {
        var form = button && button.closest ?
            button.closest("form") :
            document.getElementById("cbi-socks_batch");
        if (form) {
            var marker = form.querySelector('input[name="cbi.submit"]');
            if (!marker) {
                marker = document.createElement("input");
                marker.type = "hidden";
                marker.name = "cbi.submit";
                form.appendChild(marker);
            }
            marker.value = "1";
            button.disabled = true;
            button.textContent = "正在导入…";
            form.submit();
        } else {
            pwCenteredDialog("未找到导入表单，请刷新页面后重试。");
        }
    }
    if (document.getElementById("pw-node-clear-existing").checked) {
        pwCenteredDialog(
            "确定清空已有普通节点数据后再导入吗？",
            { confirm: true, onOk: submitForm }
        );
        return;
    }
    submitForm();
}
var importParams = new URLSearchParams(window.location.search);
if (importParams.has("imported")) {
    var importedCount = Number(importParams.get("imported")) || 0;
    var updatedCount = Number(importParams.get("updated")) || 0;
    history.replaceState(null, "", window.location.pathname);
    setTimeout(function() {
        document.getElementById("pw-node-import-success-message").textContent =
            "成功导入 " + importedCount + " 个节点\n更新 " +
            updatedCount + " 个节点";
        document.getElementById("pw-node-import-success-modal")
            .classList.add("open");
    }, 60);
}
</script>
]=]
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
    translate(
        mode == "delete" and "要删除的 SOCKS5 节点" or
        "SOCKS5 节点列表（默认全选）"
    )
)
delete_nodes_opt.widget = "checkbox"
local default_selected = {}
for _, node in ipairs(socks_nodes) do
    delete_nodes_opt:value(
        node.id,
        string.format("%s | %s:%s", node.remarks, node.address, node.port)
    )
    if mode == "check" then
        default_selected[#default_selected + 1] = node.id
    end
end
if mode == "check" then
    delete_nodes_opt.default = default_selected
end

if mode == "delete" then
    local delete_confirm_opt =
        s:option(Flag, "delete_confirm", translate("确认删除所选 SOCKS5"))
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
        m.message = translate("没有勾选有效的 SOCKS5 节点。")
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
            "( check=$(/usr/bin/curl -sS --connect-timeout 5 " ..
            "--max-time 10 --proxy-user " .. quote(auth) ..
            " --socks5-hostname " .. quote(proxy) ..
            " -o /dev/null -w '\\nCHECK_RESULT:%{http_code}:%{time_total}' " ..
            quote("https://www.baidu.com") ..
            " 2>&1); check_rc=$?; geo=''; geo_rc=1;" ..
            " if [ \"$check_rc\" -eq 0 ]; then" ..
            " geo=$(/usr/bin/curl -sS --connect-timeout 4 --max-time 8 " ..
            "--proxy-user " .. quote(auth) ..
            " --socks5-hostname " .. quote(proxy) ..
            " -A 'PassWall-SOCKS5-Check/1.0' " ..
            quote("https://ipinfo.io/json") ..
            " 2>&1); geo_rc=$?; fi;" ..
            " printf 'CHECK_RC:%s\\nCHECK_OUT:%s\\nGEO_RC:%s\\n" ..
            "GEO_OUT_BEGIN:%s\\nGEO_OUT_END\\n' " ..
            "\"$check_rc\" \"$check\" \"$geo_rc\" \"$geo\" > " ..
            quote(result) .. " ) &\n"
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
        local geo_rc = tonumber(content:match("GEO_RC:(%d+)"))
        local geo_content =
            content:match("GEO_OUT_BEGIN:(.-)\nGEO_OUT_END") or ""
        local geo = {}
        if geo_rc == 0 and geo_content ~= "" then
            pcall(function()
                local jsonc = require "luci.jsonc"
                local parsed = jsonc.parse(geo_content)
                if type(parsed) == "table" then
                    geo = parsed
                end
            end)
        end
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
        local geo_parts = {}
        for _, field in ipairs({ "country", "region", "city" }) do
            local value = trim(geo[field])
            if value ~= "" then
                geo_parts[#geo_parts + 1] = value
            end
        end
        local location = #geo_parts > 0 and
            table.concat(geo_parts, " · ") or translate("未获取")
        local location_html = html_escape(location)
        local isp = trim(geo.org)
        if isp ~= "" then
            location_html = location_html .. string.format(
                '<br><small style="opacity:.72">%s</small>',
                html_escape(isp)
            )
        end
        local sk5_ip = html_escape(
            trim(geo.ip) ~= "" and geo.ip or translate("未知")
        )
        local row_style = ok and
            "background:#eaf7ed;color:#176b2c" or
            "background:#ffe3e3;color:#9b1c1c;font-weight:600"
        rows[#rows + 1] = string.format(
            '<tr style="%s"><td>%s</td><td>%s</td><td>%s</td>' ..
            "<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
            row_style, remarks, address, sk5_ip, location_html,
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
    ) .. '<div style="overflow-x:auto;margin-top:.6em">' ..
        '<table class="cbi-section-table" ' ..
        'style="width:100%;min-width:1000px;table-layout:auto">' ..
        "<thead><tr><th>节点</th><th>SOCKS5 服务器</th><th>SOCKS5 IP</th>" ..
        "<th>归属地</th><th>状态</th><th>结果</th><th>操作</th>" ..
        "</tr></thead><tbody>" .. table.concat(shown) ..
        "</tbody></table></div>"
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
        m.message = translate("没有找到要修改的 SOCKS5 节点。")
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
        m.message = translate("请先勾选“确认删除所选 SOCKS5”。")
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
        m.message = translate("没有勾选有效的 SOCKS5 节点。")
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

    local value = tostring(http.formvalue("nodes") or "")
    local import_type =
        tostring(http.formvalue("import_type") or "socks5")
    local auto_name = http.formvalue("auto_name") == "1"
    local start_index = tonumber(http.formvalue("start_index")) or 1
    local use_group = http.formvalue("use_group") == "1"
    local node_group = trim(http.formvalue("node_group"))
    local clear_nodes = http.formvalue("clear_nodes") == "1"
    local overwrite = false
    local imported, invalid, duplicated, overwritten = 0, 0, 0, 0
    local seen = {}
    local existing = {}
    local pending = {}

    if clear_nodes then
        local sys = require("luci.sys")
        local backup = "/root/passwall.bak.nodeclear." ..
            os.date("%Y%m%d-%H%M%S")
        if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
            m.message = translate("备份 PassWall 配置失败，本次未清空节点。")
            return true
        end
        local remove_ids = {}
        local remove_set = {}
        uci:foreach("passwall", "nodes", function(node)
            local protocol = node.protocol or ""
            if protocol ~= "_shunt" and protocol ~= "_balancing" and
                protocol ~= "_urltest" and protocol ~= "_iface" then
                remove_ids[#remove_ids + 1] = node[".name"]
                remove_set[node[".name"]] = true
            end
        end)
        local shunt_ids = {}
        uci:foreach("passwall", "nodes", function(node)
            if node.protocol == "_shunt" then
                shunt_ids[#shunt_ids + 1] = node[".name"]
            end
        end)
        for _, shunt_id in ipairs(shunt_ids) do
            local options = uci:get_all("passwall", shunt_id) or {}
            for option, target_id in pairs(options) do
                if remove_set[target_id] then
                    uci:delete("passwall", shunt_id, option)
                end
            end
        end
        for _, node_id in ipairs(remove_ids) do
            uci:delete("passwall", node_id)
        end
        if not uci:commit("passwall") then
            uci:revert("passwall")
            m.message = translate("清空节点失败，本次操作已撤销。")
            return true
        end
    end

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

    local function parse_import_line(line)
        if line:match("^socks5h?://") then
            return parse_line(line)
        end
        local fields = {}
        local delimiter
        if line:find("|", 1, true) then
            delimiter = "|"
        elseif line:find(",", 1, true) then
            delimiter = ","
        elseif line:find("/", 1, true) then
            delimiter = "/"
        elseif line:find(":", 1, true) then
            delimiter = ":"
        end
        if not delimiter then
            return nil
        end
        for value in (line .. delimiter):gmatch("(.-)" ..
            delimiter:gsub("%p", "%%%0")) do
            fields[#fields + 1] = trim(value)
        end
        if #fields < 4 then
            return nil
        end
        local port = tonumber(fields[2])
        if not valid_host(fields[1]) or not port or
            port < 1 or port > 65535 then
            return nil
        end
        return {
            address = fields[1],
            port = tostring(port),
            username = fields[3] or "",
            password = fields[4] or "",
            name = fields[5]
        }
    end

    for line in (value .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" and not line:match("^#") then
            local node = parse_import_line(line)
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
            remarks = auto_name and
                string.format("socks5-node%d", start_index + imported) or
                (node.name and node.name ~= "" and node.name or
                string.format("socks5-node%d", start_index + imported)),
            address = node.address,
            port = node.port,
            username = node.username,
            password = node.password
        })

        if use_group and node_group ~= "" then
            uci:set("passwall", id, "group", node_group)
        end

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
    http.redirect(
        api.url("socks_batch") ..
        "?imported=" .. imported .. "&updated=" .. overwritten
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
    import = "批量导入分流规则",
    delete = "IP删除"
}
local m = SimpleForm("lan_batch", translate(mode_titles[mode]))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate(mode == "delete" and "删除所选 IP" or "导入")
if mode == "delete" then
    m.description = translate("勾选要删除的内网 IP/CIDR。")
end

local s = m:section(SimpleSection)

if mode == "import" then
local nodes = {}
local socks_nodes = {}
local node_groups = {}
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
    if node.group and node.group ~= "" then
        node_groups[node.group] = true
    end
end)
table.sort(socks_nodes, function(a, b)
    if a.remarks == b.remarks then
        return a.id < b.id
    end
    return a.remarks < b.remarks
end)

local function html_escape(value)
    return tostring(value or "")
        :gsub("&", "&amp;")
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
end

local shunt_node_id = nodes[1] and nodes[1].id or ""
local circled_numbers = {
    "①", "②", "③", "④"
}
local target_options = {}
for index, number in ipairs(circled_numbers) do
    target_options[#target_options + 1] = string.format(
        '<option value="%d">每目标拖 %s 终端</option>',
        index, number
    )
end
local socks_targets = {}
for _, node in ipairs(socks_nodes) do
    socks_targets[#socks_targets + 1] = {
        id = node.id,
        remarks = node.remarks
    }
end
local socks_json =
    require("luci.jsonc").stringify(socks_targets)

local assigned_sources = {}
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
        assigned_sources[#assigned_sources + 1] =
            tostring(value):lower()
    end
end)
local assigned_json =
    require("luci.jsonc").stringify(assigned_sources)

local batch_ui = s:option(
    DummyValue, "batch_shunt_ui", translate("批量导入分流规则")
)
batch_ui.rawhtml = true
batch_ui.default = [=[
<style>
#cbi-lan_batch-1-batch_shunt_ui { width:100% !important; padding:0 !important; }
#cbi-lan_batch-1-batch_shunt_ui .cbi-value-title { display:none !important; }
#cbi-lan_batch-1-batch_shunt_ui .cbi-value-field { width:100% !important; }
.cbi-map > h2,
.cbi-map > .cbi-map-title,
.cbi-map h2:first-of-type { display:none !important; margin:0 !important; }
.pw-lan-batch {
    --pw-accent:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7)))));
    --pw-bg:var(--background-color, #fff);
    --pw-surface:var(--background-color-high,
        var(--background-color, #f4f4f4));
    --pw-text:var(--text-color, #333);
    --pw-muted:var(--text-color-medium, var(--text-color, #666));
    --pw-border:var(--border-color,
        var(--border-color-high, #d8dde3));
    background:var(--pw-bg);
    color:var(--pw-text);
    margin:0 auto;
    max-width:1000px;
}
.pw-lan-title {
    background:var(--primary,
        var(--primary-color-high,
        var(--brand,
        var(--v-accent,
        var(--accent, #337ab7))))) !important;
    color:#fff;
    font-size:16px;
    font-weight:600;
    padding:8px 14px;
}
.pw-lan-body { padding:18px 20px 20px; }
.pw-lan-help {
    background:var(--pw-surface);
    color:var(--pw-muted);
    display:grid;
    font-size:14px;
    gap:12px;
    grid-template-columns:88px minmax(0, 1fr);
    line-height:1.65;
    margin-bottom:12px;
    padding:14px 18px;
}
.pw-lan-help-title { color:var(--pw-muted); }
.pw-lan-help-list { margin:0; }
.pw-lan-help-list div { margin:0; }
.pw-lan-help-examples {
    font-family:monospace;
    margin-top:2px;
    padding-left:18px;
}
.pw-lan-exclude {
    align-items:center;
    display:inline-flex !important;
    gap:7px;
    line-height:1.4;
    margin:2px 0 10px;
}
.pw-lan-exclude input[type="checkbox"] {
    flex:0 0 auto;
    margin:0 !important;
}
.pw-lan-bar {
    align-items:center;
    box-sizing:border-box;
    display:flex;
    flex-wrap:nowrap;
    gap:4px;
    justify-content:space-between;
    margin-bottom:10px;
    overflow-x:auto;
    padding-bottom:2px;
    width:100%;
    white-space:nowrap;
}
.pw-lan-bar label { flex:0 0 auto; font-size:.95em; font-weight:600; }
.pw-lan-batch .pw-lan-bar input.pw-octet.cbi-input-text {
    box-sizing:border-box !important;
    display:inline-block !important;
    flex:0 0 40px !important;
    font-variant-numeric:tabular-nums;
    margin:0 !important;
    max-width:40px !important;
    min-width:40px !important;
    padding:2px 1px !important;
    text-align:center;
    width:40px !important;
}
.pw-lan-sep { flex:0 0 auto; opacity:.65; }
.pw-lan-target { box-sizing:border-box; flex:0 1 135px; min-width:112px; max-width:150px; }
.pw-lan-btn { border:0; border-radius:3px; cursor:pointer; flex:0 0 auto; padding:6px 10px; }
.pw-lan-btn-generate { background:var(--pw-accent); color:#fff; }
.pw-lan-btn-clear {
    background:var(--pw-surface);
    color:var(--pw-text);
    border:1px solid var(--pw-border);
}
.pw-lan-text { box-sizing:border-box; min-height:300px; padding:10px; resize:vertical; width:100%; }
.pw-lan-options { margin:12px 0; }
.pw-lan-import { background:var(--pw-accent); color:#fff; min-width:100px; }
.pw-lan-cancel {
    background:var(--pw-bg);
    color:var(--pw-text);
    border:1px solid var(--pw-border);
    min-width:100px;
}
.pw-lan-actions { display:flex; justify-content:center; gap:18px; margin-top:18px; }
.cbi-page-actions { display:none !important; }
</style>
<div class="pw-lan-batch">
    <div class="pw-lan-title">批量导入分流规则</div>
    <div class="pw-lan-body">
    <input type="hidden" name="shunt_node" value="]=] ..
        html_escape(shunt_node_id) .. [=["/>
    <input type="hidden" name="target" value="_default"/>
    <input type="hidden" id="pw-lan-assigned" value="]=] ..
        html_escape(assigned_json) .. [=["/>
    <input type="hidden" id="pw-lan-socks" value="]=] ..
        html_escape(socks_json) .. [=["/>
    <input type="hidden" id="pw-lan-assignments" name="assignments" value=""/>
    <div class="pw-lan-help">
        <div class="pw-lan-help-title">帮助提示：</div>
        <div class="pw-lan-help-list">
            <div>1、使用下面的“一键生成”按钮可以批量生成配置内容，生成后仍需点击“导入”按钮才会保存该配置。</div>
            <div>2、导入相同 IP 或网段会更新已有规则；勾选“清空已有分流配置数据”会先清空全部分流规则。</div>
            <div>3、可按下方的格式输入分流规则，第二列支持节点名、节点分组、本地 WAN、SOCKS5 或 L2TP/PPTP 线路：</div>
            <div class="pw-lan-help-examples">
                <div>192.168.10.2,nodename1</div>
                <div>192.168.10.3,Group_groupname</div>
                <div>192.168.10.4,Interface:wan1</div>
                <div>192.168.10.5,l2tp_1</div>
            </div>
        </div>
    </div>
    <label class="pw-lan-exclude">
        <input id="pw-lan-exclude-assigned" type="checkbox" checked/>
        排除已分配的节点
    </label>
    <div class="pw-lan-bar">
        <label for="pw-lan-octet-1">终端IP地址范围：</label>
        <input id="pw-lan-octet-1" class="pw-octet cbi-input-text" type="text" inputmode="numeric" maxlength="3" value="192"/>
        <span class="pw-lan-sep">.</span>
        <input id="pw-lan-octet-2" class="pw-octet cbi-input-text" type="text" inputmode="numeric" maxlength="3" value="168"/>
        <span class="pw-lan-sep">.</span>
        <input id="pw-lan-octet-3" class="pw-octet cbi-input-text" type="text" inputmode="numeric" maxlength="3" value="10"/>
        <span class="pw-lan-sep">.</span>
        <input id="pw-lan-start" class="pw-octet cbi-input-text" type="text" inputmode="numeric" maxlength="3" value="1"/>
        <span class="pw-lan-sep">—</span>
        <input id="pw-lan-end" class="pw-octet cbi-input-text" type="text" inputmode="numeric" maxlength="3" value="50"/>
        <select id="pw-lan-target" class="pw-lan-target cbi-input-select" name="per_target" aria-label="每目标 IP 数量">
]=] .. table.concat(target_options) .. [=[
        </select>
        <button class="pw-lan-btn pw-lan-btn-generate" type="button" onclick="pwLanBatchGenerate()">一键生成</button>
        <button class="pw-lan-btn pw-lan-btn-clear" type="button" onclick="pwLanBatchClear()">清空配置</button>
    </div>
    <textarea id="pw-lan-source" class="pw-lan-text cbi-input-textarea" name="source" wrap="off"
        placeholder="按上述格式在此输入要导入的规则列表，分隔符可在英文逗号（,）、斜线（/）与竖线（|）中任选一种。"></textarea>
    <div class="pw-lan-options">
        <label><input id="pw-lan-clear-existing" type="checkbox" name="clear_shunt" value="1"/>
        清空已有分流配置数据</label>
    </div>
    <div class="pw-lan-actions">
        <button class="pw-lan-btn pw-lan-import" type="button" onclick="pwLanBatchSubmit()">导入</button>
        <button class="pw-lan-btn pw-lan-cancel" type="button" onclick="location.reload()">取消</button>
    </div>
    </div>
</div>
<script>
function pwCenteredDialog(message, options) {
    options = options || {};
    var overlay = document.createElement("div");
    overlay.style.cssText = "position:fixed;inset:0;z-index:3000;display:flex;" +
        "align-items:center;justify-content:center;padding:16px;" +
        "background:color-mix(in srgb,var(--text-color,#000) 38%,transparent);" +
        "box-sizing:border-box";
    var dialog = document.createElement("div");
    dialog.style.cssText = "width:100%;max-width:420px;" +
        "background:var(--background-color,#fff);color:var(--text-color,#333);" +
        "border:1px solid var(--border-color,#d8dde3);border-radius:6px;" +
        "padding:22px 24px 18px;text-align:center;box-sizing:border-box";
    var title = document.createElement("div");
    title.textContent = options.title || "提示";
    title.style.cssText = "font-size:18px;font-weight:600;margin-bottom:12px";
    var body = document.createElement("div");
    body.textContent = String(message || "");
    body.style.cssText = "white-space:pre-line;line-height:1.8;margin-bottom:18px";
    var actions = document.createElement("div");
    actions.style.cssText = "display:flex;justify-content:center;gap:12px";
    function close() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
    if (options.confirm) {
        var cancel = document.createElement("button");
        cancel.type = "button";
        cancel.textContent = "取消";
        cancel.style.cssText = "min-width:88px;padding:7px 16px;" +
            "border:1px solid var(--border-color,#d8dde3);border-radius:4px;" +
            "background:var(--background-color,#fff);" +
            "color:var(--text-color,#444);cursor:pointer";
        cancel.onclick = close;
        actions.appendChild(cancel);
    }
    var ok = document.createElement("button");
    ok.type = "button";
    ok.textContent = "确定";
    ok.style.cssText = "min-width:88px;padding:7px 16px;border:0;" +
        "border-radius:4px;background:var(--primary,var(--primary-color-high," +
        "var(--brand,var(--v-accent,var(--accent,#337ab7)))));" +
        "color:#fff;cursor:pointer";
    ok.onclick = function() {
        close();
        if (typeof options.onOk === "function") options.onOk();
    };
    actions.appendChild(ok);
    dialog.appendChild(title);
    dialog.appendChild(body);
    dialog.appendChild(actions);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
}
function pwLanBatchClear() {
    document.getElementById("pw-lan-source").value = "";
    document.getElementById("pw-lan-assignments").value = "";
}
function pwLanBatchGenerate() {
    var values = [
        "#pw-lan-octet-1", "#pw-lan-octet-2", "#pw-lan-octet-3",
        "#pw-lan-start", "#pw-lan-end"
    ].map(function(id) {
        return Number(document.querySelector(id).value);
    });
    for (var i = 0; i < 3; i++) {
        if (!Number.isInteger(values[i]) || values[i] < 0 || values[i] > 255) {
            pwCenteredDialog("前三段 IP 必须是 0-255。");
            return;
        }
    }
    if (!Number.isInteger(values[3]) || !Number.isInteger(values[4]) ||
        values[3] < 1 || values[4] > 254 || values[3] > values[4]) {
        pwCenteredDialog("终端 IP 范围无效。");
        return;
    }
    if (values[4] - values[3] + 1 > 5000) {
        pwCenteredDialog("单次最多生成 5000 个 IP。");
        return;
    }
    var perTarget = Math.max(
        1,
        Number(document.getElementById("pw-lan-target").value) || 1
    );
    var excludeAssigned = document.getElementById("pw-lan-exclude-assigned").checked;
    var assigned = [];
    var socks = [];
    try {
        assigned = JSON.parse(document.getElementById("pw-lan-assigned").value || "[]");
        socks = JSON.parse(document.getElementById("pw-lan-socks").value || "[]");
    } catch (e) {}
    if (!socks.length) {
        pwCenteredDialog("没有找到可循环绑定的 SOCKS5 节点。");
        return;
    }
    assigned = assigned.map(function(value) {
        return String(value || "").toLowerCase();
    });
    var lines = [];
    var assignments = {};
    var assignedIndex = 0;
    for (var n = values[3]; n <= values[4]; n++) {
        var ip = values[0] + "." + values[1] + "." + values[2] + "." + n;
        if (excludeAssigned && assigned.indexOf(ip.toLowerCase()) !== -1)
            continue;
        var sock = socks[Math.floor(assignedIndex / perTarget) % socks.length];
        lines.push(ip);
        assignments[ip.toLowerCase()] = sock.id || sock.remarks;
        assignedIndex++;
    }
    if (!lines.length && excludeAssigned) {
        excludeAssigned = false;
        document.getElementById("pw-lan-exclude-assigned").checked = false;
        assignedIndex = 0;
        for (var retry = values[3]; retry <= values[4]; retry++) {
            var retryIp = values[0] + "." + values[1] + "." +
                values[2] + "." + retry;
            var retrySock =
                socks[Math.floor(assignedIndex / perTarget) % socks.length];
            lines.push(retryIp);
            assignments[retryIp.toLowerCase()] =
                retrySock.id || retrySock.remarks;
            assignedIndex++;
        }
    }
    if (!lines.length) {
        pwCenteredDialog("所选范围内没有可导入的 IP。");
        return;
    }
    document.getElementById("pw-lan-source").value = lines.join("\n");
    document.getElementById("pw-lan-assignments").value =
        JSON.stringify(assignments);
}
function pwLanBatchSubmit() {
    var source = document.getElementById("pw-lan-source").value.trim();
    if (!source) {
        pwCenteredDialog("请先输入或生成规则。");
        return;
    }
    function submitForm() {
        var submit = document.querySelector(
            ".cbi-page-actions input[type=submit], " +
            ".cbi-page-actions button[type=submit]"
        );
        if (submit)
            submit.click();
    }
    if (document.getElementById("pw-lan-clear-existing").checked) {
        pwCenteredDialog(
            "确定清空已有分流配置数据后再导入吗？",
            { confirm: true, onOk: submitForm }
        );
        return;
    }
    submitForm();
}
</script>
]=]
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
    local clear_existing = http.formvalue("clear_shunt") == "1"
    local duplicate, invalid = 0, 0

    if not clear_existing then
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
    end

    local default_target = trim(http.formvalue("target"))
    local assignment_map = {}
    local assignment_json = tostring(
        http.formvalue("assignments") or ""
    )
    if assignment_json ~= "" then
        local parsed_ok, parsed_assignments =
            pcall(function()
                return require("luci.jsonc").parse(assignment_json)
            end)
        if parsed_ok and type(parsed_assignments) == "table" then
            for ip, target_name in pairs(parsed_assignments) do
                assignment_map[tostring(ip):lower()] =
                    tostring(target_name or "")
            end
        end
    end
    local raw = tostring(http.formvalue("source") or "")
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("#.*$", ""))
        if line ~= "" then
            local source, item_target
            if line:find("|", 1, true) then
                source, item_target = line:match("^(.-)|(.*)$")
            elseif line:find(",", 1, true) then
                source, item_target = line:match("^(.-),(.*)$")
            else
                local before, after = line:match("^(.-)/(.+)$")
                if before and after and not after:match("^%d+$") then
                    source, item_target = before, after
                else
                    source = line
                end
            end
            source = trim(source)
            item_target = trim(item_target)
            if item_target == "" then
                item_target = assignment_map[source:lower()] or ""
            end
            if item_target == "" then
                item_target = default_target
            end
            if #items >= 5000 then
                m.message = translate("单次最多导入 5000 个内网 IP，本次未写入。")
                return true
            end
            if not valid_source(source) then
                invalid = invalid + 1
            else
                local key = source:lower()
                local existing = seen[key]
                if existing then
                    if existing.id and existing.single then
                        items[#items + 1] = {
                            source = source,
                            id = existing.id,
                            existing = true,
                            target = item_target
                        }
                    else
                        duplicate = duplicate + 1
                    end
                else
                    seen[key] = { single = true }
                    items[#items + 1] = {
                        source = source,
                        existing = false,
                        target = item_target
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

    local network = tostring(http.formvalue("network") or "tcp,udp")
    if network ~= "tcp,udp" and network ~= "tcp" and network ~= "udp" then
        m.message = translate("网络类型无效。")
        return true
    end

    local target = trim(http.formvalue("target"))
    local node_ids = {}
    local node_remarks = {}
    local node_protocols = {}
    local node_groups = {}
    uci:foreach("passwall", "nodes", function(node)
        local name = node[".name"]
        node_ids[name] = true
        node_protocols[name] = node.protocol or ""
        if node.remarks and node.remarks ~= "" then
            node_remarks[node.remarks] = name
        end
        if node.group and node.group ~= "" then
            node_groups[node.group] = node_groups[node.group] or name
        end
    end)
    local network_names = {}
    uci:foreach("network", "interface", function(iface)
        network_names[iface[".name"]] = true
    end)

    local function resolve_target(value)
        value = trim(value)
        if value == "" or value == "_direct" or value == "_default" or
            value == "_blackhole" or value == "socks_round_robin" then
            return value
        end
        if value:match("^Group_") then
            return node_groups[value:sub(7)]
        end
        if value:match("^Interface:") then
            local iface = value:sub(11)
            if network_names[iface] then
                return value
            end
            return nil
        end
        if node_ids[value] and node_protocols[value] ~= "_shunt" then
            return value
        end
        if node_remarks[value] then
            return node_remarks[value]
        end
        if network_names[value] then
            return value
        end
        return nil
    end

    local resolved_default = resolve_target(target)
    if target ~= "" and not resolved_default then
        m.message = translate("绑定目标无效。")
        return true
    end

    local node_id = trim(http.formvalue("shunt_node"))
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

    local group = trim(http.formvalue("group"))
    if target ~= "" then
        group = node_group
    end

    local sys = require("luci.sys")
    local cleared = 0
    if clear_existing then
        local backup = "/root/passwall.bak.lanclear." ..
            os.date("%Y%m%d-%H%M%S")
        if sys.call("cp -p /etc/config/passwall " .. backup) ~= 0 then
            m.message = translate(
                "备份 PassWall 配置失败，本次未清空分流数据。"
            )
            return true
        end

        local rule_ids = {}
        local rule_set = {}
        uci:foreach("passwall", "shunt_rules", function(rule)
            local rule_id = rule[".name"]
            rule_ids[#rule_ids + 1] = rule_id
            rule_set[rule_id] = true
        end)
        local shunt_ids = {}
        uci:foreach("passwall", "nodes", function(node)
            if node.protocol == "_shunt" then
                shunt_ids[#shunt_ids + 1] = node[".name"]
            end
        end)
        for _, shunt_id in ipairs(shunt_ids) do
            local options = uci:get_all("passwall", shunt_id) or {}
            for option, value in pairs(options) do
                if type(value) == "string" and rule_set[value] then
                    uci:delete("passwall", shunt_id, option)
                end
            end
        end
        for _, rule_id in ipairs(rule_ids) do
            uci:delete("passwall", rule_id)
        end
        cleared = #rule_ids
    end

    local base = os.time()
    local serial = 0
    local imported, overwritten = 0, 0

    for index, item in ipairs(items) do
        local rule_id = item.id
        if item.existing then
            uci:set("passwall", rule_id, "network", network)
            uci:set("passwall", rule_id, "source", item.source)
            uci:set(
                "passwall", rule_id, "remarks",
                string.format("socks5-node%d", index)
            )
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
                remarks = string.format("socks5-node%d", index),
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

        local binding_target = resolve_target(item.target or target)
        if (item.target or target) ~= "" and not binding_target then
            uci:revert("passwall")
            m.message = string.format(
                translate("节点 %s 的绑定目标无效，本次导入已撤销。"),
                item.source
            )
            return true
        end
        if binding_target == "socks_round_robin" then
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

    sys.call("(/etc/init.d/passwall restart >/dev/null 2>&1 &)")
    m.message = string.format(
        translate(
            "导入完成：新增 %d 条，覆盖 %d 条，" ..
            "重复跳过 %d 个，格式错误 %d 个。"
        ),
        imported, overwritten, duplicate, invalid
    )
    if target == "socks_round_robin" then
        m.message = m.message .. string.format(
            translate(" 已循环绑定到 %d 个 SOCKS5 节点。"),
            #round_robin_nodes
        )
    end
    if clear_existing then
        m.message = m.message .. string.format(
            translate(" 已清空原有分流规则 %d 条。"),
            cleared
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
local m = SimpleForm("socks_delete", translate("SOCKS5 节点批量删除"))
m.api = api
m.is_js_luci = type(api.is_js_luci) == "function" and api.is_js_luci() or false
m.reset = false
m.submit = translate("删除所选 SOCKS5")
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

local confirm_opt = s:option(Flag, "confirm", translate("确认删除所选 SOCKS5"))
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
        m.message = translate("请先勾选“确认删除所选 SOCKS5”。")
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
        m.message = translate("没有勾选有效的 SOCKS5 节点。")
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
install_runtime_assets "$stamp"
fix_xray_source_rules
fix_sk5 "223.5.5.5"
clear_luci_cache

echo "安装完成。"
echo "打开：服务 -> PassWall -> 节点管理"
echo "打开：服务 -> PassWall -> 批量导入分流规则"
echo "如果页面未出现，请刷新浏览器或重新登录 LuCI。"
