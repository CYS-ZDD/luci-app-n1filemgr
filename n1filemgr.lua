-- N1 文件管理器（LuCI 内嵌版）
-- 菜单：网络存储 > 文件管理器
-- API: /cgi-bin/luci/admin/nas/n1filemgr/api/xxx

module("luci.controller.n1filemgr", package.seeall)

local http = require "luci.http"
local fs = require "nixio.fs"
local util = require "luci.util"

-- 兜底版本号（正常取 /usr/lib/opkg/info/luci-app-n1filemgr.control 里的 Version）
local APP_VERSION = "0.3.29"

-- 设置存在路由器本地，手机/电脑/任何浏览器打开都是同一份（localStorage 各端不互通）
local SETTINGS_FILE = "/etc/n1filemgr.json"
local jsonc_ok, jsonc = pcall(require, "luci.jsonc")

function index()
    -- 页面由 menu.d 的 view 机制渲染（保留 LuCI 框架）
    -- 这里只注册 API 路由
    entry({"admin", "nas", "n1filemgr", "api", "list"}, call("api_list")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "stat"}, call("api_stat")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "download"}, call("api_download")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "raw"}, call("api_raw")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "zipdl"}, call("api_zipdl")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "readfile"}, call("api_read")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "writefile"}, call("api_write")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "upload"}, call("api_upload")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "upload_status"}, call("api_upload_status")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "upload_cancel"}, call("api_upload_cancel")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "mkdir"}, call("api_mkdir")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "mkfile"}, call("api_mkfile")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "chmod"}, call("api_chmod")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "delete"}, call("api_delete")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "copy"}, call("api_copy")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "trash_list"}, call("api_trash_list")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "trash_restore"}, call("api_trash_restore")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "trash_delete"}, call("api_trash_delete")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "trash_empty"}, call("api_trash_empty")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "rename"}, call("api_rename")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "move"}, call("api_move")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "symlink"}, call("api_symlink")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "compress"}, call("api_compress")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "extract"}, call("api_extract")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "info"}, call("api_info")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "search"}, call("api_search")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "about"}, call("api_about")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "settings"}, call("api_settings")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "dirsize"}, call("api_dirsize")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "disk_status"}, call("api_disk_status")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "disk_info"}, call("api_disk_info")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "ztask_start"}, call("api_ztask_start")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "ztask_status"}, call("api_ztask_status")).leaf = true
    entry({"admin", "nas", "n1filemgr", "api", "ztask_cancel"}, call("api_ztask_cancel")).leaf = true
end

-- 路径/名称校验：只拒绝控制字符（NUL、换行、制表、DEL 等）。
-- 旧版用"黑名单拒绝 shell 元字符"，把手机上极常见的括号类目录名（如 手机相册备份(1)）
-- 也判成"非法路径"点不进去；而本文件所有 shell 调用都已用 util.shellquote 转义，
-- 元字符不可能造成注入，所以这里放宽为只挡控制字符。
local function has_danger(ch)
    return string.find(ch, "%c") ~= nil
end

function clean_path(p)
    if not p or p == "" then return "/" end
    if #p > 500 then return nil end
    if has_danger(p) then return nil end
    p = string.gsub(p, "//+", "/")
    return p
end

-- 名称校验：新建/重命名，拒绝斜杠与危险字符，允许中文
function clean_name(n)
    if not n or n == "" then return nil end
    if #n > 200 then return nil end
    if has_danger(n) then return nil end
    return n
end

function json_out(t)
    http.prepare_content("application/json")
    http.write_json(t or {})
end

-- 立即把 stdout 缓冲刷出去。
-- CGI 下 Lua 的 stdout 是块缓冲的，大文件下载如果等缓冲区凑满才发出，
-- 浏览器会迟迟拿不到响应头、也就迟迟不弹下载框。每个数据块后主动 flush。
local function flush_out()
    if io.stdout and io.stdout.flush then io.stdout:flush() end
end

-- Content-Disposition 里的文件名：ASCII 兜底 + RFC5987 UTF-8 编码。
-- 中文/特殊字符文件名直接塞进 header 会让部分浏览器与反向代理解析失败（远程访问下载失败的原因之一）
local function cd_filename(name)
    local ascii = string.gsub(name, "[^%w%-%._~ ]", "_")
    local esc = string.gsub(name, "([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return 'filename="' .. ascii .. '"; filename*=UTF-8\'\'' .. esc
end

-- 执行 shell 命令并判断退出码（os.execute 返回值在 LuCI 下不可靠，用 echo $? 取真实退出码）
function sh(cmd)
    os.execute(cmd .. " >/dev/null 2>&1; echo $? >/tmp/n1shrc")
    local f = io.open("/tmp/n1shrc", "r")
    local rc = tonumber(f and f:read("*a") or "1")
    if f then f:close() end
    os.remove("/tmp/n1shrc")
    return rc == 0
end

function fmt_size(n)
    n = n or 0
    if n < 1024 then return n .. " B" end
    if n < 1048576 then return string.format("%.1f KB", n / 1024) end
    if n < 1073741824 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%.2f GB", n / 1073741824)
end

function icon_for(name)
    local ext = string.lower(string.match(name, "%.([^%.]+)$") or "")
    if string.match(ext, "png|jpg|jpeg|gif|webp|svg|bmp|ico") then return "image" end
    if string.match(ext, "mp4|mkv|avi|mov|flv|wmv|ts|webm") then return "video" end
    if string.match(ext, "mp3|wav|flac|aac|ogg|m4a") then return "audio" end
    if string.match(ext, "zip|rar|7z|tar|gz|bz2|xz") then return "archive" end
    if string.match(ext, "txt|log|md|conf|cfg|ini|sh|py|lua|js|json|html|htm|css") then return "text" end
    if ext == "pdf" then return "pdf" end
    return "file"
end

function is_dir(st)
    return st and (st.type == "dir" or st.mode == "directory" or st.mode == "dir")
end

function list_dir(p)
    local entries = {}
    local ok, iter, dir_obj = pcall(fs.dir, p)
    if not ok then return entries, false end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." then
            local fp = p .. "/" .. f
            local st = fs.stat(fp)
            if st then
                local d = is_dir(st)
                table.insert(entries, {
                    name = f,
                    type = d and "dir" or "file",
                    size = d and 0 or (st.size or 0),
                    size_fmt = d and "-" or fmt_size(st.size or 0),
                    mtime = st.mtime or 0,
                    icon = d and "folder" or icon_for(f)
                })
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return a.type == "dir" end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return entries, true
end

-- ===== 页面 =====
function page()
    local html = fs.readfile("/www/luci-static/resources/n1filemgr/index.html") or ""
    http.prepare_content("text/html; charset=utf-8")
    http.write(html)
end

-- ===== API =====
function api_list()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    local entries, ok = list_dir(p)
    if not ok then json_out({ error = "无法读取目录", entries = {}, path = p }); return end
    json_out({ entries = entries, path = p, root = "/" })
end

function api_stat()
    local p = clean_path(http.formvalue("path")) or "/"
    local total, used, avail = 0, 0, 0
    local df = io.popen("df -P " .. util.shellquote(p) .. " 2>/dev/null")
    if df then
        df:read("*l")  -- header
        local line = df:read("*l")
        while line do
            local t, u, a = string.match(line, "%S+%s+(%d+)%s+(%d+)%s+(%d+)")
            if t and u and a then
                -- 单位为 1024 字节块
                total = (tonumber(t) or 0) * 1024
                used = (tonumber(u) or 0) * 1024
                avail = (tonumber(a) or 0) * 1024
                break
            end
            line = df:read("*l")
        end
        df:close()
    end
    json_out({
        total = total, used = used, available = avail,
        total_fmt = fmt_size(total), used_fmt = fmt_size(used),
        available_fmt = fmt_size(avail),
        path = p
    })
end

-- ===== eMMC 寿命探测：EXT_CSD 的 Life Time Estimation + Pre EOL + 容量 =====
local function detect_emmc()
    local dev = nil
    for i = 0, 9 do
        if io.open("/dev/mmcblk" .. i .. "boot0", "r") then
            dev = "/dev/mmcblk" .. i
            break
        end
    end
    if not dev then return nil end
    local mm = io.popen("mmc extcsd read " .. dev .. " 2>/dev/null")
    if not mm then return nil end
    local out = mm:read("*a"); mm:close()
    if not string.match(out, "PRE_EOL_INFO") then return nil end
    local a = tonumber(string.match(out, "TYP_A[^:]*:%s*0x(%x+)") or "0", 16) or 0
    local b = tonumber(string.match(out, "TYP_B[^:]*:%s*0x(%x+)") or "0", 16) or 0
    local eol = tonumber(string.match(out, "PRE_EOL_INFO[^:]*:%s*0x(%x+)") or "0", 16) or 0
    local sec = tonumber(string.match(out, "SEC_COUNT[^:]*:%s*0x(%x+)") or "0", 16) or 0
    if a == 0 and b == 0 and eol == 0 then return nil end
    local blk = string.match(dev, "mmcblk%d+") or "mmcblk1"
    local mf = io.open("/sys/block/" .. blk .. "/device/name", "r")
    local model = ""
    if mf then model = mf:read("*l") or ""; mf:close() end
    local df2 = io.open("/sys/block/" .. blk .. "/device/date", "r")
    local date = ""
    if df2 then date = df2:read("*l") or ""; df2:close() end
    return {
        name = string.match(dev, "mmcblk(%d)") or "0",
        model = model,
        date = date,
        life_a = math.max(0, 100 - a * 10),
        life_b = math.max(0, 100 - b * 10),
        eol = eol,
        size = sec * 512
    }
end

-- ===== 硬盘状态：旋转盘(rotational=1)电源模式(休眠/待命) + IO 计数(判断读写) =====
-- 只显示真正的机械硬盘：容量 >= 100GB（209715200 扇区/512B），U 盘/小容量盘不显示
function api_disk_status()
    local disks = {}
    local blk = io.popen("ls /sys/block/ 2>/dev/null")
    if blk then
        local line = blk:read("*l")
        while line do
            local d = string.match(line, "^(sd[a-z]+)$")
            if d then
                local f = io.open("/sys/block/" .. d .. "/queue/rotational", "r")
                local rot = nil
                if f then rot = f:read("*l"); f:close() end
                local sf = io.open("/sys/block/" .. d .. "/size", "r")
                local size = 0
                if sf then size = tonumber(sf:read("*l")) or 0; sf:close() end
                local rf = io.open("/sys/block/" .. d .. "/removable", "r")
                local rem = "0"
                if rf then rem = rf:read("*l") or "0"; rf:close() end
                local ef2 = io.open("/sys/block/" .. d .. "/device/ioerr_cnt", "r")
                local ioerr = 0
                if ef2 then ioerr = tonumber(ef2:read("*l")) or 0; ef2:close() end
                if string.match(rem, "^1") then
                    -- U盘/移动盘：removable=1 直接显示（不受容量限制）
                    local state = "unknown"
                    local hp = io.popen("hdparm -C /dev/" .. d .. " 2>&1")
                    if hp then
                        local out = hp:read("*a"); hp:close()
                        if string.match(out, "standby") then state = "standby"
                        elseif string.match(out, "active/idle") then state = "idle"
                        elseif string.match(out, "SG_IO") or string.match(out, "Unknown") then state = "unsupported"
                        end
                    end
                    local reads, writes = 0, 0
                    local ds = io.popen("grep ' " .. d .. " ' /proc/diskstats 2>/dev/null")
                    if ds then
                        local dl = ds:read("*l"); ds:close()
                        if dl then
                            local idx = 0
                            for w in string.gmatch(dl, "%S+") do
                                idx = idx + 1
                                if idx == 4 then reads = tonumber(w) or 0 end
                                if idx == 8 then writes = tonumber(w) or 0 end
                            end
                        end
                    end
                    table.insert(disks, { name = d, state = state, reads = reads, writes = writes, type = "usb", ioerr = ioerr })
                elseif rot and string.match(rot, "^1") and size >= 209715200 then
                    local state = "unknown"
                    local hp = io.popen("hdparm -C /dev/" .. d .. " 2>&1")
                    if hp then
                        local out = hp:read("*a"); hp:close()
                        if string.match(out, "standby") then state = "standby"
                        elseif string.match(out, "active/idle") then state = "idle"
                        elseif string.match(out, "SG_IO") or string.match(out, "Unknown") then state = "unsupported"
                        end
                    end
                    if state ~= "unsupported" then
                        local reads, writes = 0, 0
                        local ds = io.popen("grep ' " .. d .. " ' /proc/diskstats 2>/dev/null")
                        if ds then
                            local dl = ds:read("*l"); ds:close()
                            if dl then
                                local idx = 0
                                for w in string.gmatch(dl, "%S+") do
                                    idx = idx + 1
                                    if idx == 4 then reads = tonumber(w) or 0 end
                                    if idx == 8 then writes = tonumber(w) or 0 end
                                end
                            end
                        end
                        table.insert(disks, { name = d, state = state, reads = reads, writes = writes, type = "hdd", ioerr = ioerr })
                    end
                end
            end
            line = blk:read("*l")
        end
        blk:close()
    end
    json_out({ disks = disks, emmc = detect_emmc() })
end

-- ===== 磁盘详情：状态/容量/通电时长/温度/健康（smartctl + hdparm + df）=====
function api_disk_info()
    local disk = http.formvalue("disk") or ""
    if disk == "emmc" then
        local em = detect_emmc()
        if not em then
            json_out({ ok = false, err = "no emmc" })
            return
        end
        -- eMMC 文件系统/挂载点（取 ext4 主数据分区）
        local fp = io.popen("mount | grep mmcblk1 | grep -E 'type ext4' | head -1")
        local fs_type, mount = "", ""
        if fp then
            local fl = fp:read("*l")
            if fl then
                fs_type = string.match(fl, "type (%S+)") or ""
                mount = string.match(fl, " on (%S+) ") or ""
            end
            fp:close()
        end
        em.dev = "/dev/mmcblk1"
        em.fs_type = fs_type
        em.mount = mount
        json_out({ ok = true, disk = "emmc", emmc = em })
        return
    end
    if not string.match(disk, "^sd[a-z]+$") then
        json_out({ ok = false, err = "bad disk" })
        return
    end
    local dev = "/dev/" .. disk

    -- 电源状态
    local state = "unknown"
    local hp = io.popen("hdparm -C " .. util.shellquote(dev) .. " 2>&1")
    if hp then
        local out = hp:read("*a"); hp:close()
        if string.match(out, "standby") then state = "standby"
        elseif string.match(out, "active/idle") then state = "idle"
        elseif string.match(out, "SG_IO") or string.match(out, "Unknown") then state = "unsupported"
        end
    end

    -- 空间容量：取该盘第一个分区（如 sda1）的 df，顺便拿挂载点
    local total, used, avail = 0, 0, 0
    local mount = ""
    local df = io.popen("df -P " .. util.shellquote(dev .. "1") .. " 2>/dev/null")
    if df then
        df:read("*l")
        local line = df:read("*l")
        while line do
            local t, u, a, m = string.match(line, "%S+%s+(%d+)%s+(%d+)%s+(%d+)%s+%d+%%%s+(%S+)")
            if t and u and a then
                total = (tonumber(t) or 0) * 1024
                used = (tonumber(u) or 0) * 1024
                avail = (tonumber(a) or 0) * 1024
                mount = m or ""
                break
            end
            line = df:read("*l")
        end
        df:close()
    end
    -- 文件系统类型
    local fs_type = ""
    local ft = io.popen("df -T " .. util.shellquote(dev .. "1") .. " 2>/dev/null")
    if ft then
        ft:read("*l")
        local fl = ft:read("*l")
        if fl then fs_type = string.match(fl, "%S+%s+(%S+)") or "" end
        ft:close()
    end

    -- IO 计数（前端用来判断读写中）
    local reads, writes = 0, 0
    local ds = io.popen("grep ' " .. disk .. " ' /proc/diskstats 2>/dev/null")
    if ds then
        local dl = ds:read("*l"); ds:close()
        if dl then
            local idx = 0
            for w in string.gmatch(dl, "%S+") do
                idx = idx + 1
                if idx == 4 then reads = tonumber(w) or 0 end
                if idx == 8 then writes = tonumber(w) or 0 end
            end
        end
    end

    -- smartctl 全字段：型号/序列号/固件/容量/转速/SATA/支持/健康/通电时长/通电次数/温度/各项错误计数
    local model, serial, firmware, rotation, sata, smart_support, health = "", "", "", "", "", "", ""
    local capacity, hours, cycles, temp, load_cycles, gsense = 0, 0, 0, 0, 0, 0
    local raw_err, seek_err, spin_retry, realloc, realloc_evt, pending, unc, crc = 0, 0, 0, 0, 0, 0, 0, 0
    local sm = io.popen("smartctl -a " .. util.shellquote(dev) .. " 2>&1")
    if sm then
        local out = sm:read("*a"); sm:close()
        model = string.match(out, "Device Model:%s*(.-)\n") or ""
        serial = string.match(out, "Serial Number:%s*(.-)\n") or ""
        firmware = string.match(out, "Firmware Version:%s*(.-)\n") or ""
        rotation = string.match(out, "Rotation Rate:%s*(.-)\n") or ""
        sata = string.match(out, "SATA Version is:%s*(.-)\n") or ""
        sata = string.gsub(sata, "current:", "当前:")
        smart_support = string.match(out, "SMART support is:%s*(%S+)") or ""
        health = string.match(out, "result:%s*(%S+)") or ""
        local cap = string.match(out, "User Capacity:%s*([%d,]+) bytes")
        if cap then
            local capnum = string.gsub(cap, ",", "")
            capacity = tonumber(capnum) or 0
        end
        -- 属性 RAW 值通用解析（WHEN_FAILED 的 "- " 之后）
        local function ar(k)
            local l = string.match(out, k .. "[^\n]*")
            if l then return tonumber(string.match(l, "%-%s+(%d+)")) or 0 end
            return 0
        end
        hours = ar("Power_On_Hours")
        cycles = ar("Power_Cycle_Count")
        temp = ar("Temperature_Celsius")
        load_cycles = ar("Load_Cycle_Count")
        gsense = ar("G-Sense_Error_Rate")
        raw_err = ar("Raw_Read_Error_Rate")
        seek_err = ar("Seek_Error_Rate")
        spin_retry = ar("Spin_Retry_Count")
        realloc = ar("Reallocated_Sector_Ct")
        realloc_evt = ar("Reallocated_Event_Count")
        pending = ar("Current_Pending_Sector")
        unc = ar("Offline_Uncorrectable")
        crc = ar("UDMA_CRC_Error_Count")
    end
    -- smartctl 不可用时回退读 sysfs 型号/厂商/固件/容量（U盘/移动盘）
    local vendor = ""
    if model == "" then
        local mf = io.open("/sys/block/" .. disk .. "/device/model", "r")
        if mf then model = mf:read("*l") or ""; mf:close() end
        local vf = io.open("/sys/block/" .. disk .. "/device/vendor", "r")
        if vf then vendor = vf:read("*l") or ""; vf:close() end
    end
    if firmware == "" then
        local ff = io.open("/sys/block/" .. disk .. "/device/rev", "r")
        if ff then firmware = ff:read("*l") or ""; ff:close() end
    end
    if capacity == 0 then
        local sf = io.open("/sys/block/" .. disk .. "/size", "r")
        if sf then capacity = (tonumber(sf:read("*l")) or 0) * 512; sf:close() end
    end

    -- 设备类型：removable=1 视为 U盘
    local dtype = "hdd"
    local rf2 = io.open("/sys/block/" .. disk .. "/removable", "r")
    if rf2 then
        local rem = rf2:read("*l") or "0"
        rf2:close()
        if string.match(rem, "^1") then dtype = "usb" end
    end
    -- I/O 错误计数（U盘健康参考，弹窗内展示）
    local ioerr = 0
    local ef = io.open("/sys/block/" .. disk .. "/device/ioerr_cnt", "r")
    if ef then ioerr = tonumber(ef:read("*l")) or 0; ef:close() end
    -- 已完成 I/O 计数
    local iodone = 0
    local idf = io.open("/sys/block/" .. disk .. "/device/iodone_cnt", "r")
    if idf then iodone = tonumber(idf:read("*l")) or 0; idf:close() end
    -- 最近内核错误日志（无则空）
    local errlog = ""
    local eg = io.popen("dmesg 2>/dev/null | grep -iE 'sd" .. disk .. ".*(error|fail)|usb.*(reset|error)' | tail -n 1")
    if eg then
        errlog = eg:read("*l") or ""
        eg:close()
        if errlog ~= "" and #errlog > 100 then errlog = errlog:sub(1, 100) .. "..." end
    end

    json_out({
        ok = true, disk = disk, state = state,
        total = total, used = used, avail = avail,
        total_fmt = fmt_size(total), used_fmt = fmt_size(used), avail_fmt = fmt_size(avail),
        reads = reads, writes = writes,
        model = model, serial = serial, firmware = firmware, vendor = vendor,
        capacity = capacity, capacity_fmt = fmt_size(capacity),
        rotation = rotation, sata = sata, smart_support = smart_support,
        health = health, hours = hours, cycles = cycles, temp = temp,
        load_cycles = load_cycles, gsense = gsense,
        raw_err = raw_err, seek_err = seek_err, spin_retry = spin_retry,
        realloc = realloc, realloc_evt = realloc_evt, pending = pending,
        unc = unc, crc = crc,
        emmc = detect_emmc(),
        type = dtype, ioerr = ioerr, iodone = iodone, errlog = errlog,
        fs_type = fs_type, mount = mount
    })
end

-- ===== 下载：临时符号链接 + 302，交给 uhttpd 静态直发 =====
-- 之前下载走 Lua CGI 逐块输出，实测"文件越大、下载框弹出越慢"——响应被整条缓冲后浏览器才收到。
-- 改为在 /www/n1dl/<随机token> 建一个指向目标文件的符号链接并 302 过去，
-- uhttpd 用静态文件机制（sendfile）直发：响应头瞬间到达、支持断点续传、不占 Lua。
local DL_DIR = "/www/n1dl"

-- 清理超过 1 小时的下载链接和打包临时 zip
local function prune_dl()
    pcall(function()
        local now = os.time()
        for f in fs.dir(DL_DIR) do
            if f ~= "." and f ~= ".." then
                local fp = DL_DIR .. "/" .. f
                local st = fs.lstat(fp)
                if st and (now - (st.mtime or 0)) > 3600 then fs.unlink(fp) end
            end
        end
        for zf in fs.glob("/tmp/n1dl_*.zip") do
            local st = fs.stat(zf)
            if st and (now - (st.mtime or 0)) > 3600 then os.remove(zf) end
        end
        for mf in fs.glob("/tmp/n1up_*") do
            local st = fs.stat(mf)
            if st and (now - (st.mtime or 0)) > 3600 then os.remove(mf) end
        end
    end)
end

-- uhttpd 若开了 no_symlinks，静态目录不会跟随符号链接，302 到 /n1dl/xxx 会 404，
-- 这种情况直接放弃符号链接方案、走 Lua 流式输出（慢一点但一定能用）
local function symlinks_disabled()
    local cfg = fs.readfile("/etc/config/uhttpd")
    if not cfg then return false end
    return string.find(cfg, "no_symlinks%s*'?1'?") ~= nil
end

-- 在 www 下建随机符号链接，返回可直接访问的 URL 路径；失败返回 nil
-- ext：目标文件扩展名，拼在链接地址尾部。uhttpd 是按扩展名给 MIME 的，
-- 带上扩展名图片/音视频/PDF 才能被浏览器内联展示（不带就只会当二进制下载）
local function make_dl_link(target, ext)
    if symlinks_disabled() then return nil end
    prune_dl()
    local token
    do
        local rf = io.open("/dev/urandom", "rb")
        if rf then
            local b = rf:read(12)
            rf:close()
            if b and #b == 12 then
                token = string.gsub(b, ".", function(c) return string.format("%02x", string.byte(c)) end)
            end
        end
    end
    if not token or #token ~= 24 then
        token = string.format("%08x%08x", os.time(), math.floor(math.random() * 4294967295))
    end
    if not fs.access(DL_DIR) then fs.mkdir(DL_DIR) end
    local suffix = (ext and string.match(ext, "^%w+$")) and ("." .. string.lower(ext)) or ""
    local link = DL_DIR .. "/" .. token .. suffix
    if not fs.access(link) and fs.symlink(target, link) then
        return "/n1dl/" .. token .. suffix
    end
    return nil
end

-- 兜底：符号链接不可用时（如 uhttpd 开了 no_symlinks），退回 Lua 流式输出
-- inline=true 时用 inline 处置（预览），否则按附件下载
local function stream_file(p, st, ctype, disp_name, inline)
    http.header("Content-Type", ctype or "application/octet-stream")
    http.header("Content-Length", tostring((st and st.size) or 0))
    http.header("Content-Disposition", (inline and "inline; " or "attachment; ") .. cd_filename(disp_name))
    http.header("Cache-Control", "no-store")
    http.header("X-Accel-Buffering", "no")
    local f = io.open(p, "rb")
    if not f then return end
    while true do
        local chunk = f:read(262144)
        if not chunk then break end
        http.write(chunk)
        flush_out()
    end
    f:close()
    flush_out()
end

-- 扩展名 → MIME，符号链接不可用时的兜底预览用
local MIME_TYPES = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
    webp = "image/webp", bmp = "image/bmp", svg = "image/svg+xml", ico = "image/x-icon",
    mp4 = "video/mp4", webm = "video/webm", mov = "video/quicktime", mkv = "video/x-matroska",
    ts = "video/mp2t", avi = "video/x-msvideo",
    mp3 = "audio/mpeg", wav = "audio/wav", flac = "audio/flac", aac = "audio/aac",
    ogg = "audio/ogg", m4a = "audio/mp4", opus = "audio/ogg",
    pdf = "application/pdf", txt = "text/plain; charset=utf-8"
}

function api_download()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    local st = fs.stat(p)
    if not st or is_dir(st) then
        json_out({ error = "不是文件" }); return
    end
    local ext = string.match(p, "%.([%w]+)$")
    local url = make_dl_link(p, ext)
    if url then
        http.redirect(url)
        return
    end
    local name = string.match(p, "([^/]+)$") or "download"
    stream_file(p, st, MIME_TYPES[string.lower(ext or "")] or "application/octet-stream", name, false)
end

-- 内联预览：一律由 CGI 直接内联输出。
-- 之前走"符号链接 + 302"，部分环境里 uhttpd 不跟随指向 docroot 之外的符号链接，
-- 302 过去变 404，图片就在深色预览层里显示成一片黑。直发最稳，图片/音视频/PDF 都能显示。
-- 注意：iStoreOS 的 uhttpd 只白名单传少量请求头（Range 不传），CGI 侧无法实现 206；
-- 音视频在线播放由前端 fetch 全量 → blob URL 完成（见 index.html playMedia）。
function api_raw()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    local st = fs.stat(p)
    if not st or is_dir(st) then json_out({ error = "不是文件" }); return end
    local ext = string.lower(string.match(p, "%.([%w]+)$") or "")
    stream_file(p, st, MIME_TYPES[ext] or "application/octet-stream",
        string.match(p, "([^/]+)$") or "file", true)
end

-- 文本文件读取（config 编辑用，限制 512KB，拒绝二进制）
function api_read()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    if not fs.access(p) or is_dir(fs.stat(p)) then
        json_out({ error = "不是文件" }); return
    end
    local f = io.open(p, "rb")
    if not f then json_out({ error = "无法读取" }); return end
    local content = f:read(524289)
    f:close()
    if not content then content = "" end
    if #content > 524288 then json_out({ error = "文件过大（>512KB），无法编辑" }); return end
    if string.find(content, "\0") then json_out({ error = "二进制文件，无法编辑" }); return end
    json_out({ content = content })
end

-- 文本文件保存（config 编辑用，限制 512KB）
function api_write()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    local content = http.content() or ""
    if #content > 524288 then json_out({ error = "文件过大（>512KB）" }); return end
    local f = io.open(p, "wb")
    if not f then json_out({ error = "无法写入" }); return end
    f:write(content)
    f:close()
    json_out({ ok = true })
end

-- 批量打包下载：paths = 逗号分隔的路径，打包成 zip 返回
function api_zipdl()
    local paths = http.formvalue("paths") or ""
    local list = {}
    for s in string.gmatch(paths, "[^,]+") do
        local p = clean_path(s)
        if p and fs.access(p) then table.insert(list, p) end
    end
    if #list == 0 then json_out({ error = "无有效路径" }); return end
    local out = "/tmp/n1dl_" .. tostring(os.time()) .. ".zip"
    local script = [[
import zipfile, os, sys
out = sys.argv[1]
z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED)
for p in sys.argv[2:]:
    base = p.rstrip("/").rsplit("/", 1)[-1] or p
    if os.path.isdir(p):
        for root, dirs, files in os.walk(p):
            for fn in files:
                fp = os.path.join(root, fn)
                z.write(fp, (base + fp[len(p):]).lstrip("/"))
    else:
        z.write(p, base)
z.close()
]]
    local sf = "/tmp/n1zip_" .. tostring(os.time()) .. ".py"
    local f = io.open(sf, "w")
    f:write(script)
    f:close()
    local args = { out }
    for _, p in ipairs(list) do table.insert(args, p) end
    local cmd = "/usr/bin/python3 " .. util.shellquote(sf)
    for _, a in ipairs(args) do cmd = cmd .. " " .. util.shellquote(a) end
    cmd = cmd .. " >/dev/null 2>&1"
    util.exec(cmd)
    os.remove(sf)
    if not fs.access(out) then json_out({ error = "打包失败" }); return end
    -- 同样走符号链接 + 302；临时 zip 由 prune_dl 在 1 小时后回收
    local url = make_dl_link(out, "zip")
    if url then
        http.redirect(url)
        return
    end
    local ost = fs.stat(out)
    stream_file(out, ost, "application/zip", "download.zip")
    os.remove(out)
end

-- 权限校验：3-4 位八进制；nixio.fs.chmod 只接受字符串（"755"），不能转数字（493 会抛错）
function clean_mode(m)
    if not m or m == "" then return nil end
    if not string.match(m, "^[0-7][0-7][0-7]%d?$") then return nil end
    return m
end

function api_mkdir()
    local p = clean_path(http.formvalue("path"))
    local name = clean_name(http.formvalue("name"))
    local mode = clean_mode(http.formvalue("mode"))
    if not p or not name then json_out({ error = "参数不合法" }); return end
    local target = p .. "/" .. name
    if fs.access(target) then json_out({ error = "已存在" }); return end
    if not fs.mkdir(target) then json_out({ error = "创建失败" }); return end
    if mode then
        local ok = pcall(fs.chmod, target, mode)
        if not ok then json_out({ error = "权限设置失败" }); return end
    end
    json_out({ ok = true })
end

function api_mkfile()
    local p = clean_path(http.formvalue("path"))
    local name = clean_name(http.formvalue("name"))
    local mode = clean_mode(http.formvalue("mode"))
    if not p or not name then json_out({ error = "参数不合法" }); return end
    local target = p .. "/" .. name
    if fs.access(target) then json_out({ error = "已存在" }); return end
    local f = io.open(target, "wb")
    if not f then json_out({ error = "创建失败" }); return end
    f:close()
    if mode then
        local ok = pcall(fs.chmod, target, mode)
        if not ok then json_out({ error = "权限设置失败" }); return end
    end
    json_out({ ok = true })
end

function api_chmod()
    local p = clean_path(http.formvalue("path"))
    local mode = clean_mode(http.formvalue("mode"))
    if not p or not mode then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    local ok = pcall(fs.chmod, p, mode)
    if not ok then json_out({ error = "权限设置失败" }); return end
    json_out({ ok = true })
end

function api_delete()
    local p = clean_path(http.formvalue("path"))
    if not p or p == "/" then json_out({ error = "参数不合法" }); return end
    local st = fs.stat(p)
    if not st then json_out({ error = "不存在" }); return end
    -- 移入回收站（与被删文件同一文件系统，避免把系统盘 /overlay 塞满）
    -- 扁平存储：回收站内只存 basename（重名加序号），原绝对路径记入 .meta，恢复时读取
    local TRASH = trash_root_of(p)
    local base = string.match(p, "([^/]+)$") or p
    local dst = TRASH .. "/" .. base
    local i = 1
    while fs.access(dst) do
        dst = TRASH .. "/" .. base .. "_" .. i
        i = i + 1
    end
    if not sh("mkdir -p " .. util.shellquote(TRASH) .. " " .. util.shellquote(TRASH .. "/.meta")) then
        json_out({ error = "回收站创建失败" }); return
    end
    if not sh("mv " .. util.shellquote(p) .. " " .. util.shellquote(dst)) then
        json_out({ error = "移入回收站失败" }); return
    end
    local db = string.match(dst, "([^/]+)$") or base
    sh("printf '%s\\n' " .. util.shellquote(p) .. " > " .. util.shellquote(TRASH .. "/.meta/" .. db))
    json_out({ ok = true, trash = dst })
end

-- 复制：src -> dest（dest 为完整目标路径）
function api_copy()
    local src = clean_path(http.formvalue("src"))
    local dest = clean_path(http.formvalue("dest"))
    if not src or not dest or src == "/" then json_out({ error = "参数不合法" }); return end
    if not fs.access(src) then json_out({ error = "源不存在" }); return end
    if fs.access(dest) then json_out({ error = "目标已存在" }); return end
    if string.sub(dest, 1, #src) == src then json_out({ error = "不能复制到自身内部" }); return end
    if not sh("cp -a " .. util.shellquote(src) .. " " .. util.shellquote(dest)) then
        json_out({ error = "复制失败" }); return
    end
    json_out({ ok = true, to = dest })
end

-- ===== 回收站（按文件所在挂载点存放，避免塞满系统盘）=====
-- 规则：被删文件在 /（overlay 系统盘）上 → 回收站用 /tmp/.trash（tmpfs，重启自动释放）；
--       在 USB 等挂载点上 → 回收站用 <挂载点>/.trash（同盘，空间大、恢复快）。
-- 路径形态：<回收站根>/.trash/<原绝对路径去掉前导斜杠>，如 /mnt/usb1-1/.trash/mnt/usb1-1/xxx
function fs_mount_root(p)
    local h = io.popen("df -P " .. util.shellquote(p) .. " 2>/dev/null | awk 'NR==2{print $NF}'")
    local m = h and h:read("*l") or nil
    if h then h:close() end
    return (m and m ~= "") and m or "/"
end
function trash_root_of(p)
    local m = fs_mount_root(p)
    if m == "/" or m == "/overlay" then return "/tmp/.trash" end
    return m .. "/.trash"
end
-- 枚举所有回收站根（/tmp/.trash + 各挂载点 .trash），去重避免同一 .trash 被遍历两次
function trash_roots()
    local roots = { "/tmp/.trash" }
    local seen = { ["/tmp/.trash"] = true }
    local h = io.popen("df -P | awk 'NR>1 && $6 != \"/\" && $6 != \"/overlay\" {print $6}' 2>/dev/null")
    if h then
        for m in h:lines() do
            if m ~= "" and m:sub(1,1) == "/" then
                local r = m .. "/.trash"
                if not seen[r] then seen[r] = true; roots[#roots + 1] = r end
            end
        end
        h:close()
    end
    return roots
end
-- 从回收站内完整路径解析出（root, rel）：形如 <root>/.trash/<rel>
function trash_split(p)
    local i = string.find(p, "/.trash/", 1, true)
    if not i then return nil, nil end
    local root = string.sub(p, 1, i + 6)
    local rel = string.sub(p, i + 8)
    return root, rel
end

function api_trash_list()
    local entries = {}
    local count = 0
    for _, root in ipairs(trash_roots()) do
        if fs.access(root) then
            local ok, iter, dir_obj = pcall(fs.dir, root)
            if ok then
                for f in iter, dir_obj do
                    if f ~= "." and f ~= ".." and f ~= ".meta" then
                        if count >= 500 then break end
                        local full = root .. "/" .. f
                        if fs.access(root .. "/.meta/" .. f) then
                            -- 新格式（扁平存储）：直接子项即被删对象
                            local stl = fs.stat(full)
                            count = count + 1
                            table.insert(entries, {
                                name = f,
                                type = stl and is_dir(stl) and "dir" or "file",
                                size_fmt = stl and (is_dir(stl) and "目录" or fmt_size(stl.size or 0)) or "",
                                path = full
                            })
                        else
                            -- 旧格式（完整原路径）：折叠单子项目录路径链到叶子对象；
                            -- 若折叠到分叉点目录（经过了路径链），展开其直接子项作为条目
                            local disp = f
                            local cur = full
                            local jumped = false
                            local guard = 0
                            while guard < 20 do
                                local st2 = fs.stat(cur)
                                if not st2 or not is_dir(st2) then break end
                                local subs = {}
                                local ok2, iter2, dir_obj2 = pcall(fs.dir, cur)
                                if ok2 then
                                    for f2 in iter2, dir_obj2 do
                                        if f2 ~= "." and f2 ~= ".." then subs[#subs + 1] = f2 end
                                    end
                                end
                                if #subs == 1 then
                                    disp = disp .. "/" .. subs[1]
                                    cur = cur .. "/" .. subs[1]
                                    jumped = true
                                    guard = guard + 1
                                else
                                    break
                                end
                            end
                            local stl = fs.stat(cur)
                            local isd = stl and is_dir(stl)
                            if jumped and isd then
                                -- 分叉点目录：其直接子项视为被删对象
                                local ok3, iter3, dir_obj3 = pcall(fs.dir, cur)
                                if ok3 then
                                    for f3 in iter3, dir_obj3 do
                                        if f3 ~= "." and f3 ~= ".." then
                                            if count >= 500 then break end
                                            local sp = cur .. "/" .. f3
                                            local sts = fs.stat(sp)
                                            count = count + 1
                                            table.insert(entries, {
                                                name = f3,
                                                type = sts and is_dir(sts) and "dir" or "file",
                                                size_fmt = sts and (is_dir(sts) and "目录" or fmt_size(sts.size or 0)) or "",
                                                path = sp
                                            })
                                        end
                                    end
                                end
                            else
                                local lname = string.match(disp, "([^/]+)$") or disp
                                count = count + 1
                                table.insert(entries, {
                                    name = lname,
                                    type = isd and "dir" or "file",
                                    size_fmt = stl and (isd and "目录" or fmt_size(stl.size or 0)) or "",
                                    path = cur
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    json_out({ entries = entries })
end

function api_trash_restore()
    local p = clean_path(http.formvalue("path"))
    if not p or not fs.access(p) then json_out({ error = "不存在" }); return end
    local root, rel = trash_split(p)
    if not root or not rel or rel == "" then json_out({ error = "非法路径" }); return end
    local target = nil
    -- 新格式：优先读 .meta 里的原路径；旧格式回退为去掉 .trash 前缀
    local db = string.match(p, "([^/]+)$") or rel
    local mf = io.open(root .. ".meta/" .. db, "r")
    if mf then
        target = mf:read("*l") or ""
        mf:close()
    end
    if not target or target == "" then
        target = "/" .. rel
    end
    if target == "/" then json_out({ error = "非法路径" }); return end
    if fs.access(target) then json_out({ error = "原位置已存在同名项" }); return end
    local dir = string.match(target, "^(.*)/[^/]+$") or "/"
    if not sh("mkdir -p " .. util.shellquote(dir)) then json_out({ error = "目录创建失败" }); return end
    if not sh("mv " .. util.shellquote(p) .. " " .. util.shellquote(target)) then
        json_out({ error = "恢复失败" }); return
    end
    sh("rm -f " .. util.shellquote(root .. ".meta/" .. db))
    json_out({ ok = true })
end

function api_trash_delete()
    local p = clean_path(http.formvalue("path"))
    local root, rel = trash_split(p)
    if not p or not root or not rel or rel == "" then json_out({ error = "非法路径" }); return end
    local db = string.match(p, "([^/]+)$") or rel
    sh("rm -f " .. util.shellquote(root .. ".meta/" .. db))
    if not sh("rm -rf " .. util.shellquote(p)) then json_out({ error = "删除失败" }); return end
    json_out({ ok = true })
end

function api_trash_empty()
    for _, root in ipairs(trash_roots()) do
        if fs.access(root) then
            sh("rm -rf " .. util.shellquote(root) .. " && mkdir -p " .. util.shellquote(root))
        end
    end
    json_out({ ok = true })
end

function api_rename()
    local p = clean_path(http.formvalue("path"))
    local new = clean_name(http.formvalue("new"))
    if not p or not new then json_out({ error = "参数不合法" }); return end
    local nf = string.match(p, "^(.*)/[^/]+$") or "/"
    nf = nf .. "/" .. new
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    if fs.access(nf) then json_out({ error = "目标已存在" }); return end
    if not fs.rename(p, nf) then json_out({ error = "重命名失败" }); return end
    json_out({ ok = true })
end

function api_move()
    local p = clean_path(http.formvalue("path"))
    local dest = clean_path(http.formvalue("dest"))
    if not p or not dest or p == "/" then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    -- 目标必须是已存在目录
    local dst = fs.stat(dest)
    if not dst or not is_dir(dst) then json_out({ error = "目标目录不存在" }); return end
    local name = string.match(p, "([^/]+)$")
    local target = dest .. "/" .. name
    if fs.access(target) then json_out({ error = "目标已存在同名项" }); return end
    -- 防移动到自己内部
    if string.sub(dest, 1, #p) == p then json_out({ error = "不能移动到自身内部" }); return end
    -- 用 shell mv：支持跨文件系统（fs.rename 底层是 rename()，跨盘会 EXDEV 失败）
    if not sh("mv " .. util.shellquote(p) .. " " .. util.shellquote(target)) then
        json_out({ error = "移动失败" }); return
    end
    json_out({ ok = true, to = target })
end

function api_symlink()
    local p = clean_path(http.formvalue("path"))
    local name = clean_name(http.formvalue("name"))
    if not p or not name then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    local dir = string.match(p, "^(.*)/[^/]+$") or "/"
    local target = dir .. "/" .. name
    if fs.access(target) then json_out({ error = "已存在" }); return end
    if not sh("ln -s " .. util.shellquote(p) .. " " .. util.shellquote(target)) then
        json_out({ error = "创建失败" }); return
    end
    json_out({ ok = true })
end

function api_compress()
    local p = clean_path(http.formvalue("path"))
    if not p or p == "/" then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    local name = string.match(p, "([^/]+)$")
    local dir = string.match(p, "^(.*)/[^/]+$") or "/"
    -- 输出名重名自动加序号
    local out = dir .. "/" .. name .. ".tar.gz"
    local i = 1
    while fs.access(out) do
        out = dir .. "/" .. name .. "_" .. i .. ".tar.gz"
        i = i + 1
    end
    local cmd = "cd " .. util.shellquote(dir) .. " && tar czf " .. util.shellquote(out) .. " " .. util.shellquote(name)
    if not sh(cmd) then json_out({ error = "压缩失败" }); return end
    json_out({ ok = true, file = out })
end

function api_extract()
    local p = clean_path(http.formvalue("path"))
    if not p or p == "/" then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    local name = string.lower(p)
    local dir = string.match(p, "^(.*)/[^/]+$") or "/"
    local cmd
    if string.find(name, "%.tar%.gz$") then
        cmd = "cd " .. util.shellquote(dir) .. " && tar xzf " .. util.shellquote(p)
    elseif string.find(name, "%.tar%.bz2$") then
        cmd = "cd " .. util.shellquote(dir) .. " && tar xjf " .. util.shellquote(p)
    elseif string.find(name, "%.tar$") then
        cmd = "cd " .. util.shellquote(dir) .. " && tar xf " .. util.shellquote(p)
    elseif string.find(name, "%.gz$") then
        cmd = "cd " .. util.shellquote(dir) .. " && gzip -dk " .. util.shellquote(p)
    elseif string.find(name, "%.zip$") then
        cmd = "cd " .. util.shellquote(dir) .. " && unzip -o " .. util.shellquote(p)
    else
        json_out({ error = "不支持的格式（支持 tar/tar.gz/tar.bz2/tar.xz/txz/gz/zip/rar）" }); return
    end
    if not sh(cmd) then json_out({ error = "解压失败" }); return end
    json_out({ ok = true })
end

-- ===== 后台任务（压缩/解压/删除）：进度 + 取消 =====
-- 机制：启动时写 /tmp/n1zt_<id>.state(running) / .pid / .total(可选) / .log，
-- 后台 shell 逐文件处理，每处理一个写一行到 .log；前端轮询 ztask_status
-- （wc -l .log 得 done）；ztask_cancel 用 kill -TERM/-KILL 杀整个进程组（setsid 启动）。
function api_ztask_start()
    local op = http.formvalue("op")
    local p = clean_path(http.formvalue("path"))
    -- out 必须判空再 clean_path：clean_path(nil) 会返回 "/"，会把默认输出名生成逻辑跳过
    local out
    local raw_out = http.formvalue("out")
    if raw_out and raw_out ~= "" then out = clean_path(raw_out) end
    if not op or not p or p == "/" then json_out({ error = "参数不合法" }); return end
    if op ~= "compress" and op ~= "extract" and op ~= "delete" then
        json_out({ error = "不支持的操作" }); return
    end
    if not fs.access(p) then json_out({ error = "不存在" }); return end
    -- 解压前先校验格式：不支持的格式直接报错，不启动任务（7z 等 N1 未装对应工具）
    if op == "extract" then
        local lower = string.lower(p)
        local ok_fmt = lower:find("%.tar%.gz$") or lower:find("%.tgz$")
            or lower:find("%.tar%.bz2$") or lower:find("%.tar%.xz$")
            or lower:find("%.txz$") or lower:find("%.tar$")
            or lower:find("%.zip$") or lower:find("%.gz$")
            or lower:find("%.rar$")
        if not ok_fmt then
            json_out({ error = "不支持的压缩格式（支持 tar.gz/tgz/tar.bz2/tar.xz/txz/tar/zip/gz/rar）" }); return
        end
    end
    -- 压缩时若未指定输出名，按 api_compress 同款规则生成（重名自动加序号）
    if op == "compress" and not out then
        local name = string.match(p, "([^/]+)$")
        local dir = string.match(p, "^(.*)/[^/]+$") or "/"
        out = dir .. "/" .. name .. ".tar.gz"
        local i = 1
        while fs.access(out) do
            out = dir .. "/" .. name .. "_" .. i .. ".tar.gz"
            i = i + 1
        end
    end
    local id = string.format("t%x%x", os.time(), math.random(0xffffff))
    local d = "/tmp/n1zt_" .. id
    local f
    f = io.open(d .. ".state", "w"); if f then f:write("running"); f:close() end
    f = io.open(d .. ".pid", "w");   if f then f:close() end
    f = io.open(d .. ".log", "w");   if f then f:close() end
    -- 生成后台 shell 脚本（路径已 shellquote；用 gsub 占位符替换，避免 % 被 format 解析）
    local script = [[
#!/bin/sh
ID=@ID@
OP=@OP@
P=@P@
OUT=@OUT@
D=/tmp/n1zt_$ID
echo $$ > $D.pid
case $OP in
compress)
  DIR=${P%/*}
  N=${P##*/}
  echo "$DIR" > $D.dir
  find "$P" | wc -l > $D.total
  du -sb "$P" 2>/dev/null | awk '{print $1}' > $D.tsize
  (cd "$DIR" && tar czf "$OUT" -v "$N" >$D.log 2>&1)
  RC=$?
  ;;
extract)
  DIR=${P%/*}
  echo "$DIR" > $D.dir
  LOWER=$(echo "$P" | tr A-Z a-z)
  # 先统计压缩包内条目数作为总进度（进度条显示百分比 + 实时容量）
  case "$LOWER" in
    *.tar.gz|*.tgz) TOT=$(tar tzf "$P" 2>/dev/null | wc -l) ;;
    *.tar.bz2)      TOT=$(tar tjf "$P" 2>/dev/null | wc -l) ;;
    *.tar.xz|*.txz) TOT=$(tar tJf "$P" 2>/dev/null | wc -l) ;;
    *.tar)          TOT=$(tar tf "$P" 2>/dev/null | wc -l) ;;
    *.zip)          TOT=$(unzip -l "$P" 2>/dev/null | tail -1 | awk '{print $2}') ;;
    *.gz)           TOT=1 ;;
    *.rar)          TOT=$(unrar lb "$P" 2>/dev/null | wc -l) ;;
    *)              TOT=0 ;;
  esac
  if [ "$TOT" -gt 0 ] 2>/dev/null; then echo $TOT > $D.total; fi
  case "$LOWER" in
    *.tar.gz|*.tgz) (cd "$DIR" && tar xzvf "$P" >$D.log 2>&1); RC=$? ;;
    *.tar.bz2)      (cd "$DIR" && tar xjvf "$P" >$D.log 2>&1); RC=$? ;;
    *.tar.xz|*.txz) (cd "$DIR" && tar xJvf "$P" >$D.log 2>&1); RC=$? ;;
    *.tar)          (cd "$DIR" && tar xvf "$P" >$D.log 2>&1); RC=$? ;;
    *.zip)          (cd "$DIR" && unzip -o "$P" >$D.log 2>&1); RC=$? ;;
    *.gz)           gzip -dk "$P" >/dev/null 2>&1; RC=$? ;;
    *.rar)          (cd "$DIR" && unrar x -o+ "$P" "$DIR/" >$D.log 2>&1); RC=$? ;;
    *)              RC=2 ;;
  esac
  ;;
delete)
  # 回收站与被删文件同一文件系统：系统盘(/、/overlay) → /tmp/.trash；其他挂载点 → <挂载点>/.trash
  # 扁平存储：回收站内只存 basename（重名加序号），原绝对路径写入 .meta，列表/恢复时读取
  MNT=$(df -P "$P" 2>/dev/null | awk 'NR==2{print $NF}')
  if [ "$MNT" = "/" ] || [ "$MNT" = "/overlay" ]; then TRASH=/tmp/.trash; else TRASH="$MNT/.trash"; fi
  N=${P##*/}
  DST=$TRASH/$N
  i=1
  while [ -e "$DST" ]; do DST=${TRASH}/${N}_$i; i=$((i+1)); done
  mkdir -p "$TRASH/.meta"
  mv "$P" "$DST"
  printf '%s\n' "$P" > "$TRASH/.meta/${DST##*/}"
  RC=$?
  echo d >> $D.log
  ;;
esac
if [ $RC -eq 0 ]; then echo done > $D.state; else echo error > $D.state; fi
]]
    script = script:gsub("@ID@", id)
    script = script:gsub("@OP@", op)
    script = script:gsub("@P@", util.shellquote(p))
    script = script:gsub("@OUT@", (out and util.shellquote(out)) or "")
    local shf = io.open(d .. ".sh", "w")
    if not shf then json_out({ error = "任务创建失败" }); return end
    shf:write(script)
    shf:close()
    -- setsid 启动：新会话/进程组，取消时整组 kill
    os.execute("setsid sh " .. util.shellquote(d .. ".sh") .. " </dev/null >/dev/null 2>&1 &")
    json_out({ ok = true, task = id })
end

function api_ztask_status()
    local id = http.formvalue("task")
    if not id or not string.match(id, "^t%x+$") or #id > 40 then json_out({ error = "参数不合法" }); return end
    local d = "/tmp/n1zt_" .. id
    local state = "unknown"
    local sf = io.open(d .. ".state", "r")
    if sf then state = sf:read("*l") or "unknown"; sf:close() end
    local done = 0
    local lf = io.open(d .. ".log", "r")
    if lf then
        for _ in lf:lines() do done = done + 1 end
        lf:close()
    end
    local total = -1
    local tf = io.open(d .. ".total", "r")
    if tf then total = tonumber(tf:read("*l")) or -1; tf:close() end
    local tsize = -1
    local tsf = io.open(d .. ".tsize", "r")
    if tsf then tsize = tonumber(tsf:read("*l")) or -1; tsf:close() end
    -- 已处理字节数：log 每行是 tar/unzip 输出的文件名（相对 DIR），逐个 stat 累加
    local size = -1
    local df = io.open(d .. ".dir", "r")
    local dir = df and df:read("*l") or nil
    if df then df:close() end
    if dir and state ~= "unknown" then
        local sum = 0
        local n = 0
        local lf2 = io.open(d .. ".log", "r")
        if lf2 then
            for line in lf2:lines() do
                local path = line:match("^%s*[ie]%w+:%s+(.+)$") or line
                path = path:gsub("\r$", "")
                if path ~= "" and not path:find("/$") then
                    local st = fs.stat(dir .. "/" .. path)
                    if st and not is_dir(st) then
                        sum = sum + (st.size or 0)
                        n = n + 1
                    end
                    if n >= 5000 then break end
                end
            end
            lf2:close()
        end
        size = sum
    end
    -- 失败时带回日志尾部，方便前端提示具体原因（如 unrar 报错）
    local msg = nil
    if state == "error" then
        local lines = {}
        local ef = io.open(d .. ".log", "r")
        if ef then
            for line in ef:lines() do
                lines[#lines + 1] = line
                if #lines > 4 then table.remove(lines, 1) end
            end
            ef:close()
        end
        if #lines > 0 then msg = table.concat(lines, " | ") end
    end
    json_out({ state = state, done = done, total = total, size = size, tsize = tsize, msg = msg })
end

function api_ztask_cancel()
    local id = http.formvalue("task")
    if not id or not string.match(id, "^t%x+$") or #id > 40 then json_out({ error = "参数不合法" }); return end
    local d = "/tmp/n1zt_" .. id
    local pf = io.open(d .. ".pid", "r")
    local pid = pf and tonumber(pf:read("*l")) or 0
    if pf then pf:close() end
    if pid and pid > 0 then
        -- 杀整个进程组（setsid 启动后 pgid=pid）
        os.execute("kill -TERM -" .. pid .. " 2>/dev/null; sleep 1; kill -KILL -" .. pid .. " 2>/dev/null")
    end
    local sf = io.open(d .. ".state", "w")
    if sf then sf:write("cancelled"); sf:close() end
    json_out({ ok = true })
end

function api_info()
    local p = clean_path(http.formvalue("path"))
    if not p then json_out({ error = "非法路径" }); return end
    local st = fs.stat(p)
    if not st then json_out({ error = "不存在" }); return end
    local d = is_dir(st)
    -- nixio modedec 是"权限八进制字面量读作十进制"（如 0644→644），
    -- 不能用 %o 再转八进制（644 会被转成 1204），直接补零即可
    local mode_str = string.format("%04d", st.modedec or 0)
    json_out({
        name = string.match(p, "([^/]+)$") or p,
        path = p,
        type = d and "dir" or "file",
        size = d and "-" or fmt_size(st.size or 0),
        size_raw = d and 0 or (st.size or 0),
        mtime = os.date("%Y-%m-%d %H:%M:%S", st.mtime or 0),
        mode = mode_str,
        mode_raw = st.modestr or ""
    })
end

function api_search()
    local q = http.formvalue("q") or ""
    local p = clean_path(http.formvalue("path"))
    if not p then p = "/" end
    if q == "" then json_out({ results = {} }); return end
    local results = {}
    local count = 0
    local function walk(dir)
        if count >= 500 then return end
        local ok, iter, dir_obj = pcall(fs.dir, dir)
        if not ok then return end
        for f in iter, dir_obj do
            if f ~= "." and f ~= ".." then
                local fp = dir .. "/" .. f
                local st = fs.stat(fp)
                if st then
                    local d = is_dir(st)
                    if string.find(f, q, 1, true) then
                        table.insert(results, {
                            name = f,
                            type = d and "dir" or "file",
                            path = fp
                        })
                        count = count + 1
                    end
                    if d and count < 500 then
                        walk(fp)
                    end
                    if count >= 500 then break end
                end
            end
        end
    end
    walk(p)
    json_out({ results = results, query = q })
end

-- 上传（分片续传）
-- 前端把文件切成小块逐片 POST（小块能在 uhttpd/CGI 单次处理能力内完成，失败重试代价也小），
-- 后端用 http.content() 读每片（LuCI 已消费 CGI stdin，io.read 读不到，这是之前"空请求体"的根因）。
-- 参数：path=目录 name=原始文件名 offset=本片字节偏移 uid=本次上传随机标识 final=是否末片
-- 用 /tmp/n1up_<uid> 记录最终文件名：首片重试不会再产生 _1 重复文件，断点续传也能找回文件名。
-- 每片按 offset 定点写入（r+b + seek），中途失败重发同一片只覆盖半成品，不会写花整个文件。
function api_upload()
    local p = clean_path(http.formvalue("path"))
    local name = clean_name(http.formvalue("name"))
    if not p or not name then json_out({ error = "参数不合法" }); return end
    local offset = tonumber(http.formvalue("offset") or "0") or 0
    local uid = http.formvalue("uid")
    if uid and not string.match(uid, "^%x+$") then uid = nil end
    if uid and #uid > 64 then uid = nil end

    local data = http.content()
    -- 兜底：CONTENT_LENGTH 与实际读到的字节数不一致时尽量补齐，
    -- 并把"只收到半片"直接报成明确错误，而不是静默写进去半截数据
    local want = tonumber(http.getenv("CONTENT_LENGTH") or "") or 0
    if want > 0 and (not data or #data < want) then
        pcall(function()
            local inp = http.input or io.stdin
            if inp and inp.read then
                local rest = inp:read(want - #(data or ""))
                if rest and #rest > 0 then data = (data or "") .. rest end
            end
        end)
    end
    if not data or #data == 0 then json_out({ error = "空请求体" }); return end
    if want > 0 and #data < want then
        json_out({ error = "请求体不完整（收到 " .. #data .. "/" .. want .. " 字节）" }); return
    end

    local mapf = uid and ("/tmp/n1up_" .. uid) or nil
    local fname, map_existed
    if mapf then
        local mf = io.open(mapf, "r")
        if mf then
            fname = mf:read("*l")
            mf:close()
            if fname then fname = clean_name(fname) end
            map_existed = fname ~= nil
        end
    end

    if not fname then
        if offset ~= 0 then
            fname = clean_name(http.formvalue("file"))
            if not fname then json_out({ error = "缺少文件标识" }); return end
        else
            -- 首片负责定名：同名自动加序号
            local target = p .. "/" .. name
            if fs.access(target) then
                local base = target
                local i = 1
                while fs.access(target) do
                    target = base .. "_" .. i
                    i = i + 1
                end
            end
            fname = string.match(target, "([^/]+)$")
            if mapf then
                local wf = io.open(mapf, "w")
                if wf then wf:write(fname); wf:close() end
            end
        end
    end

    local full = p .. "/" .. fname
    -- 首片（且不是首片重试）截断新建；其余一律定点写，重试同一片可覆盖半成品
    local f
    if offset == 0 and not map_existed then
        f = io.open(full, "wb")
    else
        f = io.open(full, "r+b")
        if f then f:seek("set", offset)
        elseif offset == 0 then f = io.open(full, "wb") end  -- 定名映射在但文件没建成（首片重试）
    end
    if not f then json_out({ error = "无法写入（目录不可写或磁盘已满）" }); return end
    local ok, werr = pcall(function() f:write(data) end)
    f:close()
    if not ok then
        json_out({ error = "写入失败（磁盘空间不足？）" }); return
    end
    if http.formvalue("final") == "1" and mapf then os.remove(mapf) end
    json_out({ ok = true, file = fname, offset = offset, size = #data })
end

-- 上传进度查询：前端发现某片反复失败时回到这里问"已经落盘多少字节"，
-- 从断点继续，而不是整份文件从头再传
function api_upload_status()
    local p = clean_path(http.formvalue("path"))
    local uid = http.formvalue("uid")
    if not p then json_out({ error = "非法路径" }); return end
    if not uid or not string.match(uid, "^%x+$") or #uid > 64 then json_out({ size = 0 }); return end
    local fname
    local mf = io.open("/tmp/n1up_" .. uid, "r")
    if mf then fname = clean_name(mf:read("*l")); mf:close() end
    local st = fname and fs.stat(p .. "/" .. fname) or nil
    json_out({ size = st and st.size or 0, file = fname })
end

-- 取消上传：前端点了"取消"后调这里，删掉写到一半的半成品文件和 uid 映射，
-- 避免在目标目录里留下一个残缺、打不开的大文件
function api_upload_cancel()
    local p = clean_path(http.formvalue("path"))
    local uid = http.formvalue("uid")
    if not p then json_out({ error = "非法路径" }); return end
    if not uid or not string.match(uid, "^%x+$") or #uid > 64 then json_out({ ok = true }); return end
    local fname
    local mf = io.open("/tmp/n1up_" .. uid, "r")
    if mf then fname = clean_name(mf:read("*l")); mf:close() end
    if fname then pcall(fs.unlink, p .. "/" .. fname) end
    pcall(os.remove, "/tmp/n1up_" .. uid)
    json_out({ ok = true })
end

-- 关于：版本号取系统已安装包信息，避免和界面硬编码的版本号对不上
function api_about()
    local ver = ""
    local ctl = fs.readfile("/usr/lib/opkg/info/luci-app-n1filemgr.control")
    if ctl then ver = string.match(ctl, "Version:%s*([^\n\r]+)") or "" end
    ver = string.gsub(ver, "^%s+", "")
    ver = string.gsub(ver, "%s+$", "")
    if ver == "" then ver = APP_VERSION end
    json_out({ name = "luci-app-n1filemgr", version = ver, desc = "N1 文件管理器" })
end

-- 统计选中文件/目录的总大小（目录递归，深度≤10、总量≤5GB 防卡死）
function api_dirsize()
    local raw = http.formvalue("paths") or ""
    local paths = {}
    for p in raw:gmatch("[^,]+") do
        local cp = clean_path(p)
        if cp then table.insert(paths, cp) end
    end
    local sizes = {}
    local LIMIT = 5 * 1024 * 1024 * 1024
    local function calc(dir, depth)
        if depth > 10 then return 0 end
        local sum = 0
        local n = 0
        local ok, iter, dir_obj = pcall(fs.dir, dir)
        if not ok then return 0 end
        for f in iter, dir_obj do
            if f ~= "." and f ~= ".." then
                local fp = dir .. "/" .. f
                local st = fs.stat(fp)
                if st then
                    if is_dir(st) then
                        sum = sum + calc(fp, depth + 1)
                    else
                        sum = sum + (st.size or 0)
                    end
                    if sum > LIMIT then break end
                end
            end
            n = n + 1
            if n > 2000 then break end
        end
        return sum
    end
    for _, p in ipairs(paths) do
        local st = fs.stat(p)
        if st then
            sizes[p] = is_dir(st) and calc(p, 0) or (st.size or 0)
        else
            sizes[p] = -1
        end
    end
    json_out({ sizes = sizes })
end

-- ===== 设置（存在路由器本地，所有设备共享同一份）=====
local function load_settings_file()
    local t = {}
    local raw = fs.readfile(SETTINGS_FILE)
    if raw and jsonc_ok then
        local ok, parsed = pcall(jsonc.parse, raw)
        if ok and type(parsed) == "table" then t = parsed end
    end
    if raw and not next(t) then
        -- 兜底：手写极简解析，不依赖 luci.jsonc 是否存在
        local home = string.match(raw, '"home"%s*:%s*"([^"]*)"')
        if home then t.home = home end
        local view = string.match(raw, '"view"%s*:%s*"([^"]*)"')
        if view then t.view = view end
        t.showHidden = string.match(raw, '"showHidden"%s*:%s*true') ~= nil
        t.jump = string.match(raw, '"jump"%s*:%s*true') ~= nil
    end
    return t
end

function api_settings()
    if http.getenv("REQUEST_METHOD") == "POST" then
        local body = http.content() or ""
        local inp
        if jsonc_ok then
            local ok, parsed = pcall(jsonc.parse, body)
            if ok and type(parsed) == "table" then inp = parsed end
        end
        if not inp then json_out({ error = "数据格式错误" }); return end

        -- 白名单字段 + 校验，拒绝任何夹带内容；与已存设置合并（缺字段不清空）
        local out = load_settings_file()
        local h = inp.home and clean_path(inp.home) or nil
        if h and fs.access(h) then out.home = h end
        if type(inp.showHidden) == "boolean" then out.showHidden = inp.showHidden end
        if type(inp.jump) == "boolean" then out.jump = inp.jump end
        if type(inp.view) == "string" and #inp.view <= 8 then
            if string.match(inp.view, "^[%w%-]+$") then out.view = inp.view end
        end

        local function jstr(s)
            s = string.gsub(tostring(s), "\\", "\\\\")
            s = string.gsub(s, '"', '\\"')
            return '"' .. s .. '"'
        end
        local parts = {}
        if out.home then parts[#parts + 1] = '"home":' .. jstr(out.home) end
        if out.showHidden ~= nil then parts[#parts + 1] = '"showHidden":' .. (out.showHidden and "true" or "false") end
        if out.jump ~= nil then parts[#parts + 1] = '"jump":' .. (out.jump and "true" or "false") end
        if out.view then parts[#parts + 1] = '"view":' .. jstr(out.view) end
        local f = io.open(SETTINGS_FILE, "w")
        if not f then json_out({ error = "设置无法写入" }); return end
        f:write("{" .. table.concat(parts, ",") .. "}")
        f:close()
        json_out({ ok = true, settings = out })
    else
        json_out({ settings = load_settings_file() })
    end
end
