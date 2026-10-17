# luci-app-n1filemgr

OpenWrt / LuCI 的文件管理器。在 LuCI 侧边栏「NAS」分类下提供内嵌文件浏览界面，管理路由器/开发板挂载的磁盘文件。

> 个人自用项目，AI 辅助开发，随缘维护。最初为斐讯 N1（iStoreOS）定制，理论上任何 OpenWrt 环境均可使用。

## 功能特性

- **文件浏览**：浏览设备挂载的磁盘目录，面包屑导航
- **上传 / 下载**：网页直接上传文件到设备、下载设备文件
- **文件操作**：新建文件夹、重命名、复制、移动、删除（带回收站语义）
- **文本编辑**：内置编辑器直接修改文本文件
- **解压缩**：支持常见压缩包解压
- **预览**：图片 / 视频 / 音频 / PDF 内嵌预览
- **移动端适配**：小屏单列、大屏多列网格，适配 280px ~ 1024px 全宽度手机

## 依赖

- OpenWrt / iStoreOS（LuCI 环境）
- `luci-base`

## 目录结构

```
luci-app-n1filemgr/
├── n1filemgr.lua     # LuCI 控制器（RPC 后端）
├── index.html        # 前端主界面（单文件应用）
├── view.js           # LuCI iframe 渲染器（嵌入主界面）
├── menu.json         # LuCI 侧边栏菜单定义
├── acl.json          # LuCI 权限（ACL）定义
├── build_ipk.py      # ipk 打包脚本（OpenWrt gzip-tar 格式）
└── LICENSE           # GPL-2.0
```

## 安装

```sh
# 方式一：安装已打包的 ipk
opkg install luci-app-n1filemgr_*.ipk

# 方式二：手动放置源码文件
#   n1filemgr.lua  → /usr/lib/lua/luci/controller/n1filemgr.lua
#   index.html     → /www/luci-static/resources/n1filemgr/index.html
#   view.js        → /www/luci-static/resources/view/nas/n1filemgr2.js
#   menu.json      → /usr/share/luci/menu.d/luci-app-n1filemgr.json
#   acl.json       → /usr/share/rpcd/acl.d/luci-app-n1filemgr.json
```

安装后清理 LuCI 缓存并重启 Web 服务：

```sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
/etc/init.d/uhttpd restart
```

## 构建 ipk

```sh
python3 build_ipk.py
# 生成 luci-app-n1filemgr_<版本>_all.ipk
```

## 免责声明

本插件以 root / LuCI 管理员权限运行，可直接读写设备磁盘文件，**请勿将 LuCI 页面暴露到公网**。仅供学习与自用，使用风险自负。

## 许可证

[GPL-2.0](LICENSE)
