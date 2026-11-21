program test_organizer;

{ OctopusArchive 核心逻辑（organizer.pas）的控制台测试。
  编译：fpc -Fu.. test_organizer.lpr
  运行：test_organizer.exe，退出码 = 失败数 }

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, Organizer;

var
  Fails: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if Cond then
    WriteLn('  PASS: ', Msg)
  else begin
    Inc(Fails);
    WriteLn('  FAIL: ', Msg);
  end;
end;

procedure EnsureFile(const Path: string; const Content: string = 'x');
begin
  ForceDirectories(ExtractFileDir(Path));
  with TFileStream.Create(Path, fmCreate) do
    Free;
  if Content <> '' then
    with TFileStream.Create(Path, fmOpenWrite) do try
      Write(Content[1], Length(Content) * SizeOf(Char));
    finally
      Free;
    end;
end;

procedure DelTree(const Dir: string);
var
  SR: TSearchRec;
  R: Integer;
begin
  R := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR);
  try
    while R = 0 do begin
      if (SR.Name <> '.') and (SR.Name <> '..') then begin
        if (SR.Attr and faDirectory) <> 0 then
          DelTree(IncludeTrailingPathDelimiter(Dir) + SR.Name)
        else
          DeleteFile(IncludeTrailingPathDelimiter(Dir) + SR.Name);
      end;
      R := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

function BaseOpt(const Src: string): TOrganizerOptions;
begin
  Result.SourceDir := IncludeTrailingPathDelimiter(Src);
  Result.TargetDir := Result.SourceDir;  // 默认输出目录 = 源目录
  Result.Recursive := True;
  Result.IncludeHidden := False;
  Result.Action := oaMove;
  Result.Conflict := cmRename;
  Result.DeleteEmptyDirs := False;
  Result.FullnameMatch := True;
  Result.IgnoreCase := True;
  Result.ExcludeFile := 'octopusarchive.exe';
end;

function FindBySource(Plan: TPlanList; const AName: string): TPlanItem;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Plan.Count - 1 do
    if ExtractFileName(Plan[I].Source) = AName then begin
      Result := Plan[I];
      Break;
    end;
end;

function FindByPath(Plan: TPlanList; const APath: string): TPlanItem;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Plan.Count - 1 do
    if SameText(Plan[I].Source, APath) then begin
      Result := Plan[I];
      Break;
    end;
end;

function TargetEndsWith(Item: TPlanItem; const Tail: string): Boolean;
begin
  Result := (Item <> nil) and (Pos(Lowercase(Tail), Lowercase(Item.Target)) > 0);
end;

{ 工具函数单测 }
procedure TestHelpers;
var
  Maps: TFormatMaps;
  Row: TFormatMapRow;
begin
  WriteLn('== 工具函数 ==');
  Check(NormalizeExtList(' jpg, JPEG，png') = 'jpg,jpeg,png', 'NormalizeExtList 混合分隔符+去重');
  Check(NormalizeExtList('...txt;; doc') = 'txt,doc', 'NormalizeExtList 去点+空段');
  Check(ExtListHas('jpg,jpeg', '.JPG') = True, 'ExtListHas 忽略大小写和点');
  Check(ExtListHas('jpg,jpeg', 'gif') = False, 'ExtListHas 不存在');
  Maps := TFormatMaps.Create;
  try
    Row := TFormatMapRow.Create;
    Row.ExtList := 'jpg,jpeg';
    Row.Folder := '';
    Maps.Add(Row);
    Check(MapEffectiveFolder(Row) = 'jpg', '目录名留空默认取第一个扩展名');
    Row.Folder := '图片';
    Check(MapEffectiveFolder(Row) = '图片', '手动目录名生效');
  finally
    Maps.Free;
  end;
end;

{ 功能①：按格式分组 }
procedure TestFeature1;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Maps: TFormatMaps;
  Log: TStringList;
  Row: TFormatMapRow;
  Src: string;
  It: TPlanItem;
begin
  WriteLn('== 功能1：按格式分组 ==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Maps := TFormatMaps.Create;
  Log := TStringList.Create;
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t1';
    DelTree(Src);
    Opt := BaseOpt(Src);
    EnsureFile(Src + '\a.jpg', 'a');
    EnsureFile(Src + '\B.JPG', 'B');
    EnsureFile(Src + '\b.jpeg');
    EnsureFile(Src + '\c.txt');
    EnsureFile(Src + '\noext');
    EnsureFile(Src + '\sub\sub2\d.jpg');
    EnsureFile(Src + '\sub\e.pdf');
    EnsureFile(Src + '\hiddenfile.txt');
    FileSetAttr(Src + '\hiddenfile.txt', faHidden);

    Row := TFormatMapRow.Create;
    Row.ExtList := 'jpg,jpeg';
    Row.Folder := '图片';
    Maps.Add(Row);
    Row := TFormatMapRow.Create;
    Row.ExtList := 'txt';
    Row.Folder := '';
    Maps.Add(Row);

    Org.BuildPlanFeature1(Opt, Maps, Plan, nil, nil);
    Check(Plan.Count = 7, Format('计划数 = 7（隐藏文件被排除），实际 %d', [Plan.Count]));
    Check(Org.NoOpCount = 0, '无已到位文件');
    It := FindBySource(Plan, 'a.jpg');
    Check(TargetEndsWith(It, '\图片\a.jpg'), 'a.jpg → 图片 目录');
    It := FindBySource(Plan, 'B.JPG');
    Check(TargetEndsWith(It, '\图片\b.jpg'), '.JPG 并入小写 jpg 组（保留原名）');
    It := FindBySource(Plan, 'b.jpeg');
    Check(TargetEndsWith(It, '\图片\b.jpeg'), 'jpeg 并入映射组');
    It := FindBySource(Plan, 'c.txt');
    Check(TargetEndsWith(It, '\txt\c.txt'), '映射留空 → 默认 txt 目录');
    It := FindBySource(Plan, 'noext');
    Check(TargetEndsWith(It, '\_noext\noext'), '无扩展名 → _noext');
    It := FindBySource(Plan, 'e.pdf');
    Check(TargetEndsWith(It, '\pdf\e.pdf'), '未列出的扩展名自动建目录');
    It := FindBySource(Plan, 'd.jpg');
    Check(TargetEndsWith(It, '\图片\d.jpg'), '深层递归命中');

    Run := TRunRecord.Create('T1');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(Run.Items.Count = 7, '撤销日志 7 条');
    Check(FileExists(Src + '\图片\a.jpg') and FileExists(Src + '\图片\b.jpeg')
      and FileExists(Src + '\图片\B.JPG') and FileExists(Src + '\图片\d.jpg')
      and FileExists(Src + '\txt\c.txt') and FileExists(Src + '\_noext\noext')
      and FileExists(Src + '\pdf\e.pdf'), '目标文件全部到位');
    Check(not FileExists(Src + '\a.jpg') and not FileExists(Src + '\sub\sub2\d.jpg')
      and not FileExists(Src + '\sub\e.pdf'), '源文件已移走');
    Check(FileExists(Src + '\hiddenfile.txt'), '隐藏文件未被处理');

    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\a.jpg') and FileExists(Src + '\B.JPG')
      and FileExists(Src + '\sub\sub2\d.jpg') and FileExists(Src + '\sub\e.pdf')
      and FileExists(Src + '\c.txt') and FileExists(Src + '\noext'),
      '撤销后源文件全部恢复（含重建子目录）');
    Check(not FileExists(Src + '\图片\a.jpg') and not FileExists(Src + '\pdf\e.pdf'),
      '撤销后目标目录已清空');
    Check((not DirectoryExists(Src + '\图片')) and (not DirectoryExists(Src + '\txt'))
      and (not DirectoryExists(Src + '\_noext')) and (not DirectoryExists(Src + '\pdf')),
      '撤销后执行时新建的分类目录已删除');
    Run.Free;
  finally
    Plan.Free;
    Maps.Free;
    Log.Free;
    Org.Free;
  end;
end;

{ 功能②：打平目录 + 冲突改名 + 删空目录 + 撤销 }
procedure TestFeature2;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Log: TStringList;
  Src: string;
  It: TPlanItem;
begin
  WriteLn('== 功能2：打平目录 ==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Log := TStringList.Create;
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t2';
    DelTree(Src);
    Opt := BaseOpt(Src);
    Opt.DeleteEmptyDirs := True;
    EnsureFile(Src + '\x\a.txt', 'a');
    EnsureFile(Src + '\x\y\b.txt', 'b');
    EnsureFile(Src + '\top.txt', 'top');
    EnsureFile(Src + '\x\top.txt', 'x-top');

    Org.BuildPlanFlatten(Opt, Plan, nil, nil);
    Check(Plan.Count = 3, Format('计划数 = 3（顶层文件跳过），实际 %d', [Plan.Count]));
    Check(Org.NoOpCount = 1, '顶层 top.txt 计入已到位');
    Check(FindByPath(Plan, Src + '\top.txt') = nil, '顶层 top.txt 不在计划中');
    It := FindBySource(Plan, 'a.txt');
    Check(TargetEndsWith(It, '\t2\a.txt'), 'a.txt → 顶层');
    It := FindBySource(Plan, 'b.txt');
    Check(TargetEndsWith(It, '\t2\b.txt'), 'b.txt → 顶层');
    It := FindByPath(Plan, Src + '\x\top.txt');
    Check((It <> nil) and TargetEndsWith(It, '\t2\top_1.txt'), '重名 top.txt 改名为 top_1.txt');

    Run := TRunRecord.Create('T2');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\a.txt') and FileExists(Src + '\b.txt')
      and FileExists(Src + '\top.txt') and FileExists(Src + '\top_1.txt'), '打平后文件到位');
    Check(not DirectoryExists(Src + '\x'), '清空的子目录 x 被删除');

    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\x\a.txt') and FileExists(Src + '\x\y\b.txt')
      and FileExists(Src + '\x\top.txt') and (not FileExists(Src + '\top_1.txt')),
      '撤销后打平恢复（含重建 x\y 目录与改名还原）');
  finally
    Run.Free;
    Plan.Free;
    Log.Free;
    Org.Free;
  end;
end;

{ 功能③：正则分类 }
procedure TestFeature3;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Rules: TRegexRules;
  Log: TStringList;
  Errs: TStringList;
  Rule: TRegexRuleRow;
  Src: string;
  It: TPlanItem;
begin
  WriteLn('== 功能3：按正则分类 ==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Rules := TRegexRules.Create;
  Log := TStringList.Create;
  Errs := TStringList.Create;
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t3';
    DelTree(Src);
    Opt := BaseOpt(Src);
    EnsureFile(Src + '\report2024.docx', 'r1');
    EnsureFile(Src + '\other.docx');
    EnsureFile(Src + '\sub\BACKUP_1.zip', 'z');
    EnsureFile(Src + '\sub\reportOLD.docx', 'r2');
    EnsureFile(Src + '\sub\2024-01.txt', 'm');

    Rule := TRegexRuleRow.Create;
    Rule.Pattern := '^report.*\.docx$';
    Rule.Folder := 'invoices';
    Rules.Add(Rule);
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := 'backup';
    Rule.Folder := '';
    Rules.Add(Rule);
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := '^\d{4}-\d{2}';
    Rule.Folder := 'monthly';
    Rules.Add(Rule);

    // 正则校验
    ValidateRegexRules(Rules, True, Errs);
    Check(Errs.Count = 0, '合法正则通过校验');
    Errs.Clear;
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := '[';
    Rule.Folder := 'x';
    Rules.Add(Rule);
    ValidateRegexRules(Rules, True, Errs);
    Check(Errs.Count = 1, '非法正则被校验捕获');
    Rules.Delete(Rules.Count - 1);

    Org.BuildPlanRegex(Opt, Rules, Plan, nil, nil);
    Check(Plan.Count = 4, Format('计划数 = 4（未匹配不动），实际 %d', [Plan.Count]));
    It := FindBySource(Plan, 'report2024.docx');
    Check(TargetEndsWith(It, '\invoices\report2024.docx'), '规则1 命中 → invoices');
    It := FindBySource(Plan, 'reportOLD.docx');
    Check(TargetEndsWith(It, '\invoices\reportOLD.docx'), '忽略大小写 + 递归命中');
    It := FindBySource(Plan, 'BACKUP_1.zip');
    Check(TargetEndsWith(It, '\t3\BACKUP_1.zip'), '规则2 空目录名 → 源顶层');
    Check((It <> nil) and SameText(It.Source, Src + '\sub\BACKUP_1.zip'), '规则2 源来自子目录');
    It := FindBySource(Plan, '2024-01.txt');
    Check(TargetEndsWith(It, '\monthly\2024-01.txt'), '规则3 → monthly');
    It := FindBySource(Plan, 'other.docx');
    Check(It = nil, '未匹配文件不进计划');

    Run := TRunRecord.Create('T3');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\invoices\report2024.docx') and FileExists(Src + '\invoices\reportOLD.docx')
      and FileExists(Src + '\BACKUP_1.zip') and FileExists(Src + '\monthly\2024-01.txt'),
      '正则分类执行到位');
    Check(FileExists(Src + '\other.docx'), '未匹配文件保持原地');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\report2024.docx') and FileExists(Src + '\sub\reportOLD.docx')
      and FileExists(Src + '\sub\2024-01.txt') and FileExists(Src + '\sub\BACKUP_1.zip')
      and (not FileExists(Src + '\invoices\report2024.docx')),
      '正则分类撤销恢复');
    Check((not DirectoryExists(Src + '\invoices')) and (not DirectoryExists(Src + '\monthly')),
      '正则撤销后新建的分类目录已删除');
    Run.Free;

    // 中文名正则（UTF-8 源码）
    WriteLn('  -- 中文名匹配 --');
    Rules.Clear;
    EnsureFile(Src + '\报告2024.docx', 'cn');
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := '^报告.*\.docx$';
    Rule.Folder := '票据';
    Rules.Add(Rule);
    Org.BuildPlanRegex(Opt, Rules, Plan, nil, nil);
    It := FindBySource(Plan, '报告2024.docx');
    Check(TargetEndsWith(It, '\票据\报告2024.docx'), '中文正则 + 中文目录名');
    Run := TRunRecord.Create('T3cn');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\票据\报告2024.docx'), '中文文件执行到位');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\报告2024.docx'), '中文文件撤销恢复');
    Check(not DirectoryExists(Src + '\票据'), '中文撤销后新建目录已删除');
    Run.Free;
  finally
    Plan.Free;
    Rules.Free;
    Log.Free;
    Errs.Free;
    Org.Free;
  end;
end;

{ 冲突策略：skip / overwrite }
procedure TestConflict;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Log: TStringList;
  Buf: string;
  Src: string;
  It: TPlanItem;
begin
  WriteLn('== 冲突策略 ==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Log := TStringList.Create;
  Run := TRunRecord.Create('T4');
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t4';
    DelTree(Src);
    Opt := BaseOpt(Src);
    EnsureFile(Src + '\a.txt', 'top-content');
    EnsureFile(Src + '\sub\a.txt', 'sub-content');

    Opt.Conflict := cmSkip;
    Org.BuildPlanFlatten(Opt, Plan, nil, nil);
    It := FindBySource(Plan, 'a.txt');
    Check((It <> nil) and (It.State = pisSkipped), 'skip 模式：冲突项标记跳过');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\sub\a.txt'), 'skip 模式：源文件保留');
    Run.Items.Clear;

    Opt.Conflict := cmOverwrite;
    Org.BuildPlanFlatten(Opt, Plan, nil, nil);
    It := FindBySource(Plan, 'a.txt');
    Check((It <> nil) and It.WillOverwrite, 'overwrite 模式：标记将覆盖');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\a.txt') and (not FileExists(Src + '\sub\a.txt')), 'overwrite 执行完成');
    with TFileStream.Create(Src + '\a.txt', fmOpenRead) do try
      SetLength(Buf, Size);
      Read(Buf[1], Size);
    finally
      Free;
    end;
    Check(Buf = 'sub-content', '覆盖后内容为源文件内容');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\sub\a.txt'), 'overwrite 后撤销：位置恢复');
  finally
    Run.Free;
    Plan.Free;
    Log.Free;
    Org.Free;
  end;
end;

{ 复制模式 }
procedure TestCopy;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Log: TStringList;
  Src: string;
begin
  WriteLn('== 复制模式 ==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Log := TStringList.Create;
  Run := TRunRecord.Create('T5');
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t5';
    DelTree(Src);
    Opt := BaseOpt(Src);
    Opt.Action := oaCopy;
    EnsureFile(Src + '\sub\a.txt', 'copy-me');
    Org.BuildPlanFlatten(Opt, Plan, nil, nil);
    Check(Plan.Count = 1, '复制计划 1 项');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(Src + '\sub\a.txt') and FileExists(Src + '\a.txt'), '复制后两处都有');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\sub\a.txt') and (not FileExists(Src + '\a.txt')),
      '复制撤销：删除副本，源保留');
  finally
    Run.Free;
    Plan.Free;
    Log.Free;
    Org.Free;
  end;
end;

{ 输出目录：TargetDir ≠ SourceDir 时三个功能的去向 }
procedure TestTargetDir;
var
  Org: TOrganizer;
  Opt: TOrganizerOptions;
  Plan: TPlanList;
  Run: TRunRecord;
  Maps: TFormatMaps;
  Rules: TRegexRules;
  Log: TStringList;
  Row: TFormatMapRow;
  Rule: TRegexRuleRow;
  Src, OutD: string;
  It: TPlanItem;
begin
  WriteLn('== 输出目录（TargetDir）==');
  Org := TOrganizer.Create;
  Plan := TPlanList.Create;
  Maps := TFormatMaps.Create;
  Rules := TRegexRules.Create;
  Log := TStringList.Create;
  Run := TRunRecord.Create('T6');
  try
    Src := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t6\src';
    OutD := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t6\out';
    DelTree(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp\t6');
    Opt := BaseOpt(Src);
    Opt.TargetDir := IncludeTrailingPathDelimiter(OutD);

    // 功能①：分组目录建在输出目录下
    EnsureFile(Src + '\a.jpg', 'a');
    EnsureFile(Src + '\top.txt', 't');
    EnsureFile(Src + '\sub\b.txt', 'b');
    Row := TFormatMapRow.Create;
    Row.ExtList := 'txt';
    Row.Folder := 'docs';
    Maps.Add(Row);
    Org.BuildPlanFeature1(Opt, Maps, Plan, nil, nil);
    Check(TargetEndsWith(FindBySource(Plan, 'a.jpg'), '\out\jpg\a.jpg'),
      '功能① jpg → 输出目录\jpg');
    Check(TargetEndsWith(FindBySource(Plan, 'top.txt'), '\out\docs\top.txt'),
      '功能① 顶层文件也归入输出目录');
    Check(TargetEndsWith(FindBySource(Plan, 'b.txt'), '\out\docs\b.txt'),
      '功能① 子目录文件归入输出目录');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(OutD + '\jpg\a.jpg') and FileExists(OutD + '\docs\top.txt')
      and FileExists(OutD + '\docs\b.txt'), '功能① 输出目录文件到位');
    Check((not FileExists(Src + '\a.jpg')) and (not FileExists(Src + '\top.txt')),
      '功能① 源文件已移走');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\a.jpg') and FileExists(Src + '\top.txt')
      and FileExists(Src + '\sub\b.txt') and (not FileExists(OutD + '\jpg\a.jpg')),
      '功能① 撤销恢复源文件、输出目录清空');
    Check(not DirectoryExists(OutD), '功能① 撤销后新建的输出目录链已整体删除');
    Run.Items.Clear;

    // 功能②：打平到输出目录顶层（输出≠源时，源顶层文件也会被收集）
    DelTree(Src);
    DelTree(OutD);
    EnsureFile(Src + '\top.txt', 't');
    EnsureFile(Src + '\sub\a.txt', 'a');
    Org.BuildPlanFlatten(Opt, Plan, nil, nil);
    Check(Plan.Count = 2, Format('功能② 计划数 = 2（输出≠源时顶层文件也收集），实际 %d',
      [Plan.Count]));
    Check(Org.NoOpCount = 0, '功能② 输出≠源：无已到位文件');
    Check(TargetEndsWith(FindBySource(Plan, 'top.txt'), '\out\top.txt'),
      '功能② 顶层文件 → 输出目录顶层');
    Check(TargetEndsWith(FindBySource(Plan, 'a.txt'), '\out\a.txt'),
      '功能② 子目录文件 → 输出目录顶层');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(OutD + '\top.txt') and FileExists(OutD + '\a.txt')
      and (not FileExists(Src + '\top.txt')) and (not FileExists(Src + '\sub\a.txt')),
      '功能② 输出到位、源清空');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\top.txt') and FileExists(Src + '\sub\a.txt')
      and (not FileExists(OutD + '\top.txt')), '功能② 撤销恢复');
    Run.Items.Clear;

    // 功能③：分类目录相对输出目录（含多级子路径）
    DelTree(Src);
    DelTree(OutD);
    EnsureFile(Src + '\report2024.docx', 'r');
    EnsureFile(Src + '\sub\other.docx', 'o');
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := '^report';
    Rule.Folder := 'invoices\2024';
    Rules.Add(Rule);
    Org.BuildPlanRegex(Opt, Rules, Plan, nil, nil);
    It := FindBySource(Plan, 'report2024.docx');
    Check(TargetEndsWith(It, '\out\invoices\2024\report2024.docx'),
      '功能③ 相对输出目录分类（含子路径）');
    Check(FindBySource(Plan, 'other.docx') = nil, '功能③ 未匹配不动');
    Org.ExecutePlan(Opt, Plan, Run, Log, nil, nil);
    Check(FileExists(OutD + '\invoices\2024\report2024.docx'), '功能③ 输出到位');
    Check(FileExists(Src + '\sub\other.docx'), '功能③ 未匹配文件保持原地');
    Org.UndoRun(Run, Log, nil, nil);
    Check(FileExists(Src + '\report2024.docx')
      and (not FileExists(OutD + '\invoices\2024\report2024.docx')), '功能③ 撤销恢复');
    Check(not DirectoryExists(OutD), '功能③ 撤销后新建目录链（多层）已删除');
  finally
    Run.Free;
    Plan.Free;
    Maps.Free;
    Rules.Free;
    Log.Free;
    Org.Free;
  end;
end;

begin
  // 与 LCL 应用一致：文件系统与默认字符串编码统一为 UTF-8，
  // 保证中文文件名/中文正则的行为与 GUI 下完全相同
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;
  try
    DelTree(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp');
    TestHelpers;
    TestFeature1;
    TestFeature2;
    TestFeature3;
    TestConflict;
    TestCopy;
    TestTargetDir;
    WriteLn;
    WriteLn(Format('共 %d 项检查，失败 %d 项。', [Checks, Fails]));
  except
    on E: Exception do begin
      WriteLn('异常: ', E.Message);
      Fails := Fails + 1;
    end;
  end;
  if Fails > 0 then
    ExitCode := 1
  else
    ExitCode := 0;
end.
