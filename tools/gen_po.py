# -*- coding: utf-8 -*-
"""Generate languages/OctopusArchive.en.po from the project .rsj files + LFM inventory.
msgid = Chinese original (from rsj sourcebytes), msgstr = English translation
(reused from the existing hand-written po), `#:` identifiers = exact rsj names
for resourcestrings and stack-path guesses for LFM entries (msgid fallback covers
any imprecision at runtime).
"""
import json, re, sys

ROOT = r"D:/code/ahk_pro/octopus-archive"
RSJ = [ROOT + "/lib/x86_64-win64/main.rsj", ROOT + "/lib/x86_64-win64/organizer.rsj"]
OLD_PO = ROOT + "/languages/OctopusArchive.en.po"
OUT_PO = OLD_PO

def rsj_entries(path):
    d = json.load(open(path, encoding="utf-8"))
    out = []
    for s in d["strings"]:
        name = s["name"]                       # e.g. main.rsprocessingfmt
        msgid = bytes(s["sourcebytes"]).decode("utf-8")
        out.append((name, msgid))
    return out

def parse_old_po(text):
    """Extract msgid->msgstr from the existing hand-written po (flat, single-line entries)."""
    trans = {}
    cur_id, cur_st = None, None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r'^msgid "(.*)"$', line)
        if m:
            cur_id, cur_st = m.group(1), None
            continue
        m = re.match(r'^msgstr "(.*)"$', line)
        if m and cur_id is not None:
            cur_st = m.group(1)
            if cur_id and cur_st:
                trans[cur_id] = cur_st
            cur_id = None
    return trans

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

# LFM entries: (identifier, msgid). msgstr comes from the translation map.
LFM = [
    ("tformmain.caption", "OctopusArchive 文件整理工具"),
    ("tformmain.pnltop.pnlrow1.lblsrc.caption", "源目录"),
    ("tformmain.pnltop.pnlrow1.btnbrowse.caption", "浏览…"),
    ("tformmain.pnltop.pnlrow2.lblout.caption", "输出目录"),
    ("tformmain.pnltop.pnlrow2.btnoutbrowse.caption", "浏览…"),
    ("tformmain.pnltop.pnlrow2.edtout.texthint", "留空 = 与源目录相同"),
    ("tformmain.pnltop.pnlrow3.lblmode.caption", "模式"),
    ("tformmain.pnltop.pnlrow3.lblconflict.caption", "重名冲突"),
    ("tformmain.pnltop.pnlrow3.chkrecursive.caption", "含子目录"),
    ("tformmain.pnltop.pnlrow3.chkhidden.caption", "含隐藏/系统文件"),
    ("tformmain.pnlstatus.lblstatus.caption", "就绪"),
    ("tformmain.pnlbottom.pnlactions.btnpreview.caption", "预览"),
    ("tformmain.pnlbottom.pnlactions.btnexecute.caption", "执行"),
    ("tformmain.pnlbottom.pnlactions.btnundo.caption", "撤销本次"),
    ("tformmain.pnlbottom.pnlactions.btncancelrun.caption", "取消"),
    ("tformmain.pcmain.tsformat.caption", "按格式分组"),
    ("tformmain.pcmain.tsformat.pnlfmttools.btnmapadd.caption", "添加一行"),
    ("tformmain.pcmain.tsformat.pnlfmttools.btnmapdel.caption", "删除所选行"),
    ("tformmain.pcmain.tsformat.lblformathelp.caption",
     "说明：扩展名统一转小写做目录名（.JPG 和 .jpg 同组），分组目录建在输出目录下；无扩展名文件进 _noext 目录；未列出的扩展名自动按自身扩展名建目录，映射表只负责合并与改名。"),
    ("tformmain.pcmain.tsflatten.caption", "打平目录"),
    ("tformmain.pcmain.tsflatten.lblflattenhelp.caption",
     "说明：把源目录（含子目录）中的文件移动/复制到输出目录顶层；输出目录默认为源目录（此时顶层已有文件保持不动）；重名冲突按顶部设置处理；重复执行是安全的（已到位的文件自动跳过）。"),
    ("tformmain.pcmain.tsflatten.chkdelempty.caption", "执行（移动）后删除已清空的子目录"),
    ("tformmain.pcmain.tsregex.caption", "按正则分类"),
    ("tformmain.pcmain.tsregex.pnlregtools.btnruleadd.caption", "添加一行"),
    ("tformmain.pcmain.tsregex.pnlregtools.btnruledel.caption", "删除所选行"),
    ("tformmain.pcmain.tsregex.pnlregtools.btnruleup.caption", "上移"),
    ("tformmain.pcmain.tsregex.pnlregtools.btnruledown.caption", "下移"),
    ("tformmain.pcmain.tsregex.pnlregopts.chkfullname.caption", "匹配完整文件名（含扩展名）"),
    ("tformmain.pcmain.tsregex.pnlregopts.chkignorecase.caption", "忽略大小写"),
    ("tformmain.pcmain.tsregex.lblregexhelp.caption",
     "说明：规则按列表顺序匹配，第一个命中的规则生效；未匹配的文件保持不动；目标目录名相对输出目录（可含子路径），留空 = 移到输出目录顶层。类 PCRE 语法。"),
]

trans = parse_old_po(open(OLD_PO, encoding="utf-8").read())
print("translation map:", len(trans), "entries")

# 执行确认正文由一条多行 msgid 拆成 4 行（po 的 \n 展开为换行符难以精确匹配）
trans.update({
    "确定执行「%s」？": "Execute \"%s\"?",
    "模式：%s · 冲突处理：%s": "Mode: %s · Conflict handling: %s",
    "源目录：%s": "Source folder: %s",
    "输出目录：%s": "Output folder: %s",
})

lines = [
    "# English translation for OctopusArchive.",
    "# Base language is Chinese (embedded in the source code and forms).",
    "# Generated from lib/*/x86_64-win64/*.rsj (resourcestrings) + main.lfm inventory.",
    '# NOTE: every entry needs a "#: identifier" comment -- entries without one',
    "# are discarded by FPC's po parser (TPOFile.ReadPOText).",
    'msgid ""',
    'msgstr ""',
    '"Project-Id-Version: OctopusArchive\\n"',
    '"Content-Type: text/plain; charset=UTF-8\\n"',
    "",
]

missing = []
seen = set()

def emit(ident, msgid):
    if msgid in seen:
        return
    seen.add(msgid)
    st = trans.get(msgid)
    if st is None:
        missing.append(msgid)
        st = ""
    lines.append("#: " + ident)
    lines.append('msgid "%s"' % esc(msgid))
    lines.append('msgstr "%s"' % esc(st))
    lines.append("")

for path in RSJ:
    for name, msgid in rsj_entries(path):
        emit(name, msgid)

for ident, msgid in LFM:
    emit(ident, msgid)

open(OUT_PO, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print("written:", OUT_PO, len(seen), "entries")
if missing:
    print("MISSING TRANSLATIONS:")
    for m in missing:
        print("  ", m)
    sys.exit(1)
print("all translated")

# 英文 po 内嵌进 exe：windres 把 langres.rc（引用 po）编译成 langres.res，
# .lpr 里 {$R langres.res} 链接。改了翻译必须重跑本脚本，否则 exe 里还是旧译文。
import subprocess
WINDRES = r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\windres.exe"
r = subprocess.run([WINDRES, ROOT + "/langres.rc", "-O", "coff", "-o", ROOT + "/langres.res"],
                   cwd=ROOT, capture_output=True, text=True)
if r.returncode != 0:
    print("windres failed:", (r.stderr or "").strip())
    sys.exit(1)
print("written:", ROOT + "/langres.res")
