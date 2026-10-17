# -*- coding: utf-8 -*-
"""打包 luci-app-n1filemgr（OpenWrt 24.10 gzip-tar 格式）"""
import io, os, sys, tarfile, gzip, hashlib

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "luci-app-n1filemgr_0.3.29_all.ipk")

def read_bin(p):
    with open(p, "rb") as f:
        return f.read()

def to_lf(data):
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

# ===== 数据文件 =====
data_files = [
    ("usr/lib/lua/luci/controller/n1filemgr.lua",
     to_lf(read_bin(os.path.join(BASE, "n1filemgr.lua")))),
    ("www/luci-static/resources/n1filemgr/index.html",
     to_lf(read_bin(os.path.join(BASE, "index.html")))),
    ("www/luci-static/resources/view/nas/n1filemgr2.js",
     to_lf(read_bin(os.path.join(BASE, "view.js")))),
    ("usr/share/luci/menu.d/luci-app-n1filemgr.json",
     to_lf(read_bin(os.path.join(BASE, "menu.json")))),
    ("usr/share/rpcd/acl.d/luci-app-n1filemgr.json",
     to_lf(read_bin(os.path.join(BASE, "acl.json")))),
]

control_content = to_lf(("""Package: luci-app-n1filemgr
Version: 0.3.29
Depends: libc, luci-base
SourceName: luci-app-n1filemgr
License: GPL-2.0
Architecture: all
Installed-Size: 60
Description: N1 文件管理器 - LuCI 内嵌侧边栏文件浏览器

""").encode("utf-8"))

debian_binary = b"2.0\n"

def build_tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for name, content in entries:
            if name.endswith("/"):
                ti = tarfile.TarInfo(name)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
            else:
                ti = tarfile.TarInfo(name)
                ti.mode = 0o644
            ti.size = len(content)
            ti.mtime = 0
            ti.uid = 0; ti.gid = 0
            ti.uname = "root"; ti.gname = "root"
            tf.addfile(ti, io.BytesIO(content))
    return buf.getvalue()

# data.tar.gz：目录 + 文件
data_entries = []
seen_dirs = set()
for path, content in data_files:
    parts = path.split("/")
    for i in range(1, len(parts)):
        d = "/".join(parts[:i])
        if d not in seen_dirs:
            seen_dirs.add(d)
            data_entries.append((d + "/", b""))
    data_entries.append((path, content))

# control.tar.gz
control_entries = [
    ("./control", control_content),
]
if os.path.exists(os.path.join(BASE, "postinst")):
    control_entries.append(("./postinst", to_lf(read_bin(os.path.join(BASE, "postinst")))))

data_tgz = build_tar_gz(data_entries)
control_tgz = build_tar_gz(control_entries)

# 外层 tar + gzip
outer_buf = io.BytesIO()
with tarfile.open(fileobj=outer_buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
    for name, content in [("debian-binary", debian_binary),
                          ("control.tar.gz", control_tgz),
                          ("data.tar.gz", data_tgz)]:
        ti = tarfile.TarInfo(name)
        ti.size = len(content)
        ti.mode = 0o644
        ti.mtime = 0
        ti.uid = 0; ti.gid = 0
        tf.addfile(ti, io.BytesIO(content))

raw = outer_buf.getvalue()
# 外层 gzip（tar 内容）
comp = gzip.compress(raw, mtime=0)

with open(OUT, "wb") as f:
    f.write(comp)

print("IPK:", OUT)
print("SIZE:", len(comp), "bytes")
print("SHA256:", hashlib.sha256(comp).hexdigest())
