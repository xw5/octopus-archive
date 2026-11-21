unit Organizer;

{ OctopusArchive 核心逻辑：扫描、生成计划、执行、撤销。
  不依赖 LCL，纯 SysUtils/FGL/RegExpr，便于单独测试。 }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, RegExpr;

const
  ConfigFileName = 'octopus_archive.ini';
  NoExtFolder = '_noext';

type
  TOpAction = (oaMove, oaCopy);
  TConflictMode = (cmRename, cmSkip, cmOverwrite);

  { TFormatMapRow - 功能①的格式映射行 }
  TFormatMapRow = class
  public
    ExtList: string;  // 已规范化：小写、无点、逗号分隔，如 'jpg,jpeg'
    Folder: string;   // 可为空：空 = 默认取第一个扩展名
  end;
  TFormatMaps = specialize TFPGObjectList<TFormatMapRow>;

  { TRegexRuleRow - 功能③的正则规则行 }
  TRegexRuleRow = class
  public
    Pattern: string;
    Folder: string;   // 可为空：空 = 移到源目录顶层
  end;
  TRegexRules = specialize TFPGObjectList<TRegexRuleRow>;

  TPlanItemState = (pisPending, pisDone, pisSkipped, pisFailed);

  { TPlanItem - 一条待执行操作 }
  TPlanItem = class
  public
    Source: string;
    Target: string;
    Note: string;
    WillOverwrite: Boolean;
    DirConflict: Boolean;   // 目标同名目录，拒绝处理
    State: TPlanItemState;
    ErrMsg: string;
  end;
  TPlanList = specialize TFPGObjectList<TPlanItem>;

  { TUndoEntry - 撤销日志条目 }
  TUndoEntry = class
  public
    Source: string;
    Target: string;
    WasCopy: Boolean;
  end;
  TUndoList = specialize TFPGObjectList<TUndoEntry>;

  { TRunRecord }
  TRunRecord = class
  public
    Title: string;
    Items: TUndoList;
    CreatedDirs: TStringList;  // 执行时由 ForceDirectories 新建的目录（撤销时若已空则一并删除）
    constructor Create(const ATitle: string);
    destructor Destroy; override;
  end;
  TRunList = specialize TFPGObjectList<TRunRecord>;

  TOrganizerOptions = record
    SourceDir: string;       // 必须带尾部分隔符
    TargetDir: string;       // 输出目录（带尾分隔符）；留空 = 等于 SourceDir
    Recursive: Boolean;
    IncludeHidden: Boolean;
    Action: TOpAction;
    Conflict: TConflictMode;
    DeleteEmptyDirs: Boolean;  // 打平后删除空子目录
    FullnameMatch: Boolean;    // 正则匹配完整文件名（否则仅主文件名）
    IgnoreCase: Boolean;       // 正则忽略大小写
    ExcludeFile: string;       // 跳过的文件名（小写，通常是工具自身 exe）
  end;

  TProgressEvent = procedure(Current, Total: Integer; const Info: string) of object;
  TCheckCancel = function: Boolean of object;
  TFileFoundEvent = procedure(const APath: string) of object;

  TRegExprList = specialize TFPGObjectList<TRegExpr>;

  function NormalizeExtList(const S: string): string;
  function ExtListHas(const List, AExt: string): Boolean;
  function MapEffectiveFolder(ARow: TFormatMapRow): string;
  function ExtToFolder(const AExt: string): string;
  procedure ValidateRegexRules(Rules: TRegexRules; IgnoreCase: Boolean; Errs: TStrings);

type

  { TOrganizer }
  TOrganizer = class
  private
    FCancelled: Boolean;
    FNoOpCount: Integer;
    FCollectList: TStrings;
    procedure CollectFile(const APath: string);
    procedure ScanDir(const Dir: string; const Opt: TOrganizerOptions;
      OnFound: TFileFoundEvent; OnProgress: TProgressEvent; OnCancel: TCheckCancel;
      var ACount: Integer);
    procedure ScanFiles(const Opt: TOrganizerOptions; OnFound: TFileFoundEvent;
      OnProgress: TProgressEvent; OnCancel: TCheckCancel);
    procedure ResolveTarget(const Opt: TOrganizerOptions; Item: TPlanItem);
    procedure RecordNewDirs(const ADir: string; Run: TRunRecord);
    procedure CopyFileContents(const Src, Dst: string);
    function DirIsEmpty(const Dir: string): Boolean;
    procedure RemoveEmptyDirs(const Dir: string; Log: TStrings);
  public
    constructor Create;
    // 功能①：按格式分组
    procedure BuildPlanFeature1(const Opt: TOrganizerOptions; Maps: TFormatMaps;
      Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
    // 功能②：打平目录
    procedure BuildPlanFlatten(const Opt: TOrganizerOptions;
      Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
    // 功能③：按文件名正则分类
    procedure BuildPlanRegex(const Opt: TOrganizerOptions; Rules: TRegexRules;
      Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
    // 执行计划，记录撤销日志
    procedure ExecutePlan(const Opt: TOrganizerOptions; Plan: TPlanList; Run: TRunRecord;
      Log: TStrings; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
    // 撤销一次执行，返回失败数
    function UndoRun(Run: TRunRecord; Log: TStrings; OnProgress: TProgressEvent;
      OnCancel: TCheckCancel): Integer;
    property Cancelled: Boolean read FCancelled;
    property NoOpCount: Integer read FNoOpCount;
  end;

implementation

{ 用户可见文本（预览备注/错误/日志），resourcestring 供 i18n 翻译 }
resourcestring
  rsRegexInvalidFmt   = '规则 %d 的正则无效：%s（%s）';
  rsNoteTargetExists  = '目标已存在，跳过';
  rsNoteDirConflict   = '目标存在同名目录，无法处理';
  rsNoteOverwrite     = '将覆盖目标同名文件';
  rsNoteRenamed       = '重名 → 已改名';
  rsLogDelEmptyFmt    = '删除空目录: %s';
  rsErrDirConflict    = '目标存在同名目录，拒绝处理';
  rsErrMoveFailed     = '移动失败：无法删除源文件（已回滚）';
  rsLogFailFmt        = '失败: %s → %s';
  rsErrUndoCopyDel    = '无法删除复制产生的文件';
  rsErrUndoTargetDel  = '无法删除目标文件';
  rsLogUndoFailFmt    = '撤销失败: %s → %s';
  rsLogDelEmptyUndoFmt = '删除空目录（撤销）: %s';

{ TRunRecord }

constructor TRunRecord.Create(const ATitle: string);
begin
  inherited Create;
  Title := ATitle;
  Items := TUndoList.Create;
  CreatedDirs := TStringList.Create;
end;

destructor TRunRecord.Destroy;
begin
  CreatedDirs.Free;
  Items.Free;
  inherited Destroy;
end;

{ 工具函数 }

function CleanExt(const E: string): string;
var
  T: string;
begin
  T := Lowercase(Trim(E));
  while (T <> '') and (T[1] = '.') do
    Delete(T, 1, 1);
  Result := T;
end;

function NormalizeExtList(const S: string): string;
var
  Tmp: string;
  Parts, Seen: TStringList;
  I: Integer;
  Tok: string;
begin
  Tmp := StringReplace(S, '；', ',', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, '，', ',', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, ';', ',', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, ' ', ',', [rfReplaceAll]);
  Tmp := StringReplace(Tmp, #9, ',', [rfReplaceAll]);
  Parts := TStringList.Create;
  Seen := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Tmp;
    for I := 0 to Parts.Count - 1 do begin
      Tok := CleanExt(Parts[I]);
      if Tok = '' then
        Continue;
      if Seen.IndexOf(Tok) >= 0 then
        Continue;
      Seen.Add(Tok);
    end;
    Result := Seen.CommaText;
  finally
    Parts.Free;
    Seen.Free;
  end;
end;

function ExtListHas(const List, AExt: string): Boolean;
var
  E: string;
begin
  E := CleanExt(AExt);
  Result := (E <> '') and (Pos(',' + E + ',', ',' + List + ',') > 0);
end;

function MapEffectiveFolder(ARow: TFormatMapRow): string;
var
  Parts: TStringList;
begin
  Result := Trim(ARow.Folder);
  if Result <> '' then
    Exit;
  // 目录名留空：默认取扩展名列表的第一个
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := ARow.ExtList;
    if Parts.Count > 0 then
      Result := Parts[0];
  finally
    Parts.Free;
  end;
end;

function ExtToFolder(const AExt: string): string;
begin
  Result := CleanExt(AExt);
  if Result = '' then
    Result := NoExtFolder;
end;

procedure ValidateRegexRules(Rules: TRegexRules; IgnoreCase: Boolean; Errs: TStrings);
var
  I: Integer;
  RE: TRegExpr;
begin
  for I := 0 to Rules.Count - 1 do begin
    RE := TRegExpr.Create;
    try
      RE.ModifierI := IgnoreCase;
      RE.Expression := Rules[I].Pattern;
      RE.Compile;
    except
      on E: Exception do
        Errs.Add(Format(rsRegexInvalidFmt, [I + 1, Rules[I].Pattern, E.Message]));
    end;
    RE.Free;
  end;
end;

{ TOrganizer }

constructor TOrganizer.Create;
begin
  inherited Create;
  FCancelled := False;
  FNoOpCount := 0;
  FCollectList := nil;
end;

procedure TOrganizer.CollectFile(const APath: string);
begin
  FCollectList.Add(APath);
end;

procedure TOrganizer.ScanDir(const Dir: string; const Opt: TOrganizerOptions;
  OnFound: TFileFoundEvent; OnProgress: TProgressEvent; OnCancel: TCheckCancel;
  var ACount: Integer);
var
  SR: TSearchRec;
  R: Integer;
begin
  if Assigned(OnCancel) and OnCancel() then begin
    FCancelled := True;
    Exit;
  end;
  R := FindFirst(Dir + '*', faAnyFile, SR);
  try
    while R = 0 do begin
      if (SR.Name <> '.') and (SR.Name <> '..') then begin
        if (SR.Attr and faDirectory) <> 0 then begin
          if Opt.Recursive then
            ScanDir(Dir + SR.Name + PathDelim, Opt, OnFound, OnProgress, OnCancel, ACount);
        end else begin
          if (not Opt.IncludeHidden) and ((SR.Attr and (faHidden or faSysFile)) <> 0) then begin
            // 跳过隐藏/系统文件
          end else if SameText(SR.Name, ConfigFileName)
            or ((Opt.ExcludeFile <> '') and SameText(SR.Name, Opt.ExcludeFile)) then begin
            // 跳过工具自身的配置与 exe
          end else begin
            Inc(ACount);
            if Assigned(OnFound) then
              OnFound(Dir + SR.Name);
            if Assigned(OnProgress) and (ACount mod 200 = 0) then
              OnProgress(ACount, 0, Dir + SR.Name);
          end;
        end;
      end;
      if Assigned(OnCancel) and OnCancel() then begin
        FCancelled := True;
        Break;
      end;
      R := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;
end;

procedure TOrganizer.ScanFiles(const Opt: TOrganizerOptions; OnFound: TFileFoundEvent;
  OnProgress: TProgressEvent; OnCancel: TCheckCancel);
var
  Count: Integer;
begin
  Count := 0;
  ScanDir(Opt.SourceDir, Opt, OnFound, OnProgress, OnCancel, Count);
end;

procedure TOrganizer.ResolveTarget(const Opt: TOrganizerOptions; Item: TPlanItem);
var
  Base, Ext: string;
  N: Integer;
begin
  if not (FileExists(Item.Target) or DirectoryExists(Item.Target)) then
    Exit;
  case Opt.Conflict of
    cmSkip:
      begin
        Item.State := pisSkipped;
        Item.Note := rsNoteTargetExists;
      end;
    cmOverwrite:
      begin
        if DirectoryExists(Item.Target) then begin
          Item.DirConflict := True;
          Item.Note := rsNoteDirConflict;
        end else begin
          Item.WillOverwrite := FileExists(Item.Target);
          if Item.WillOverwrite then
            Item.Note := rsNoteOverwrite;
        end;
      end;
    cmRename:
      begin
        Base := ChangeFileExt(Item.Target, '');
        Ext := ExtractFileExt(Item.Target);
        N := 1;
        while FileExists(Item.Target) or DirectoryExists(Item.Target) do begin
          Item.Target := Format('%s_%d%s', [Base, N, Ext]);
          Inc(N);
        end;
        Item.Note := rsNoteRenamed;
      end;
  end;
end;

{ 记录执行时将要新建的目录链：从 ADir 向上收集到第一个已存在的祖先为止。
  撤销时按"先深后浅"删除这些已变空的目录（非空则保留）。 }
procedure TOrganizer.RecordNewDirs(const ADir: string; Run: TRunRecord);
var
  Cur, Up: string;
  I: Integer;
  Found: Boolean;
begin
  if Run = nil then
    Exit;
  Cur := ExcludeTrailingPathDelimiter(ADir);
  while (Cur <> '') and (Length(Cur) > 3) and (not DirectoryExists(Cur)) do begin
    Found := False;
    for I := 0 to Run.CreatedDirs.Count - 1 do
      if SameText(Run.CreatedDirs[I], Cur) then begin
        Found := True;
        Break;
      end;
    if not Found then
      Run.CreatedDirs.Add(Cur);
    Up := ExcludeTrailingPathDelimiter(ExtractFileDir(Cur));
    if Up = Cur then  // 已到根
      Break;
    Cur := Up;
  end;
end;

procedure TOrganizer.CopyFileContents(const Src, Dst: string);
var
  InStream, OutStream: TFileStream;
begin
  InStream := TFileStream.Create(Src, fmOpenRead or fmShareDenyWrite);
  try
    OutStream := TFileStream.Create(Dst, fmCreate);
    try
      OutStream.CopyFrom(InStream, InStream.Size);
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

function TOrganizer.DirIsEmpty(const Dir: string): Boolean;
var
  SR: TSearchRec;
  R: Integer;
begin
  Result := True;
  R := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR);
  try
    while (R = 0) and Result do begin
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Result := False
      else
        R := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;
end;

procedure TOrganizer.RemoveEmptyDirs(const Dir: string; Log: TStrings);
var
  SR: TSearchRec;
  R: Integer;
  Sub: string;
begin
  R := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR);
  try
    while R = 0 do begin
      if (SR.Name <> '.') and (SR.Name <> '..') and ((SR.Attr and faDirectory) <> 0) then begin
        Sub := IncludeTrailingPathDelimiter(Dir) + SR.Name;
        RemoveEmptyDirs(Sub, Log);
        if DirIsEmpty(Sub) then
          if RemoveDir(Sub) then begin
            if Log <> nil then
              Log.Add(Format(rsLogDelEmptyFmt, [Sub]));
          end;
      end;
      R := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;
end;

procedure TOrganizer.BuildPlanFeature1(const Opt: TOrganizerOptions; Maps: TFormatMaps;
  Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
var
  Files: TStringList;
  I, R: Integer;
  Item: TPlanItem;
  Ext, Folder, Target: string;
begin
  Plan.Clear;
  FNoOpCount := 0;
  FCancelled := False;
  Files := TStringList.Create;
  try
    FCollectList := Files;
    ScanFiles(Opt, @CollectFile, OnProgress, OnCancel);
    if FCancelled then
      Exit;
    for I := 0 to Files.Count - 1 do begin
      if Assigned(OnCancel) and OnCancel() then begin
        FCancelled := True;
        Exit;
      end;
      Ext := Lowercase(ExtractFileExt(Files[I]));
      Folder := '';
      if Maps <> nil then
        for R := 0 to Maps.Count - 1 do
          if ExtListHas(Maps[R].ExtList, Ext) then begin
            Folder := MapEffectiveFolder(Maps[R]);
            Break;
          end;
      if Folder = '' then
        Folder := ExtToFolder(Ext);
      Target := Opt.TargetDir + Folder + PathDelim + ExtractFileName(Files[I]);
      if SameText(Files[I], Target) then begin
        Inc(FNoOpCount);
        Continue;
      end;
      Item := TPlanItem.Create;
      Item.Source := Files[I];
      Item.Target := Target;
      ResolveTarget(Opt, Item);
      Plan.Add(Item);
      if Assigned(OnProgress) then
        OnProgress(I + 1, Files.Count, Files[I]);
    end;
  finally
    Files.Free;
    FCollectList := nil;
  end;
end;

procedure TOrganizer.BuildPlanFlatten(const Opt: TOrganizerOptions;
  Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
var
  Files: TStringList;
  I: Integer;
  Item: TPlanItem;
  Target: string;
begin
  Plan.Clear;
  FNoOpCount := 0;
  FCancelled := False;
  Files := TStringList.Create;
  try
    FCollectList := Files;
    ScanFiles(Opt, @CollectFile, OnProgress, OnCancel);
    if FCancelled then
      Exit;
    for I := 0 to Files.Count - 1 do begin
      if Assigned(OnCancel) and OnCancel() then begin
        FCancelled := True;
        Exit;
      end;
      Target := Opt.TargetDir + ExtractFileName(Files[I]);
      if SameText(Files[I], Target) then begin
        Inc(FNoOpCount);
        Continue;
      end;
      Item := TPlanItem.Create;
      Item.Source := Files[I];
      Item.Target := Target;
      ResolveTarget(Opt, Item);
      Plan.Add(Item);
      if Assigned(OnProgress) then
        OnProgress(I + 1, Files.Count, Files[I]);
    end;
  finally
    Files.Free;
    FCollectList := nil;
  end;
end;

procedure TOrganizer.BuildPlanRegex(const Opt: TOrganizerOptions; Rules: TRegexRules;
  Plan: TPlanList; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
var
  Files: TStringList;
  REs: TRegExprList;
  I, R: Integer;
  Item: TPlanItem;
  RE: TRegExpr;
  FName, Subject, Folder, Target: string;
  Matched: Boolean;
begin
  Plan.Clear;
  FNoOpCount := 0;
  FCancelled := False;
  Files := TStringList.Create;
  REs := TRegExprList.Create;
  try
    // 预编译规则（无效规则置 nil 跳过，正常情况下已提前校验过）
    for R := 0 to Rules.Count - 1 do begin
      try
        RE := TRegExpr.Create;
        RE.ModifierI := Opt.IgnoreCase;
        RE.Expression := Rules[R].Pattern;
        RE.Compile;
      except
        on E: Exception do begin
          RE.Free;
          RE := nil;
        end;
      end;
      REs.Add(RE);
    end;
    FCollectList := Files;
    ScanFiles(Opt, @CollectFile, OnProgress, OnCancel);
    if FCancelled then
      Exit;
    for I := 0 to Files.Count - 1 do begin
      if Assigned(OnCancel) and OnCancel() then begin
        FCancelled := True;
        Exit;
      end;
      FName := ExtractFileName(Files[I]);
      if Opt.FullnameMatch then
        Subject := FName
      else
        Subject := ChangeFileExt(FName, '');
      Folder := '';
      Matched := False;
      for R := 0 to Rules.Count - 1 do
        if (REs[R] <> nil) and REs[R].Exec(Subject) then begin
          Folder := Rules[R].Folder;
          Matched := True;
          Break;
        end;
      if not Matched then
        Continue;  // 未匹配的文件保持不动
      if Folder = '' then
        Target := Opt.TargetDir + FName
      else
        Target := Opt.TargetDir + Folder + PathDelim + FName;
      if SameText(Files[I], Target) then begin
        Inc(FNoOpCount);
        Continue;
      end;
      Item := TPlanItem.Create;
      Item.Source := Files[I];
      Item.Target := Target;
      ResolveTarget(Opt, Item);
      Plan.Add(Item);
      if Assigned(OnProgress) then
        OnProgress(I + 1, Files.Count, Files[I]);
    end;
  finally
    Files.Free;
    REs.Free;
    FCollectList := nil;
  end;
end;

procedure TOrganizer.ExecutePlan(const Opt: TOrganizerOptions; Plan: TPlanList;
  Run: TRunRecord; Log: TStrings; OnProgress: TProgressEvent; OnCancel: TCheckCancel);
var
  I: Integer;
  Item: TPlanItem;
  U: TUndoEntry;
  Canceled: Boolean;
begin
  Canceled := False;
  for I := 0 to Plan.Count - 1 do begin
    Item := Plan[I];
    if Assigned(OnCancel) and OnCancel() then begin
      FCancelled := True;
      Canceled := True;
      Break;
    end;
    if Item.State <> pisPending then begin
      if Assigned(OnProgress) then
        OnProgress(I + 1, Plan.Count, Item.Source);
      Continue;
    end;
    try
      if Item.DirConflict then
        raise Exception.Create(rsErrDirConflict);
      if (Run <> nil) and (not DirectoryExists(ExtractFileDir(Item.Target))) then
        RecordNewDirs(ExtractFileDir(Item.Target), Run);
      ForceDirectories(ExtractFileDir(Item.Target));
      if Opt.Action = oaCopy then begin
        if Item.WillOverwrite then
          DeleteFile(Item.Target);
        CopyFileContents(Item.Source, Item.Target);
        U := TUndoEntry.Create;
        U.Source := Item.Source;
        U.Target := Item.Target;
        U.WasCopy := True;
        Run.Items.Add(U);
      end else begin
        if Item.WillOverwrite then
          DeleteFile(Item.Target);
        if not RenameFile(Item.Source, Item.Target) then begin
          // 跨盘移动：复制 + 删除源
          CopyFileContents(Item.Source, Item.Target);
          if not DeleteFile(Item.Source) then begin
            DeleteFile(Item.Target);
            raise Exception.Create(rsErrMoveFailed);
          end;
        end;
        U := TUndoEntry.Create;
        U.Source := Item.Source;
        U.Target := Item.Target;
        U.WasCopy := False;
        Run.Items.Add(U);
      end;
      Item.State := pisDone;
    except
      on E: Exception do begin
        Item.State := pisFailed;
        Item.ErrMsg := E.Message;
        if Log <> nil then
          Log.Add(Format(rsLogFailFmt, [Item.Source, E.Message]));
      end;
    end;
    if Assigned(OnProgress) then
      OnProgress(I + 1, Plan.Count, Item.Source);
  end;
  // 打平 + 移动模式下清理空目录
  if (not Canceled) and Opt.DeleteEmptyDirs and (Opt.Action = oaMove) then
    RemoveEmptyDirs(Opt.SourceDir, Log);
end;

function CompareDirDepth(List: TStringList; I1, I2: Integer): Integer;
begin
  // 长路径排前面：撤销清理时先删最深的目录
  Result := Length(List[I2]) - Length(List[I1]);
end;

function TOrganizer.UndoRun(Run: TRunRecord; Log: TStrings; OnProgress: TProgressEvent;
  OnCancel: TCheckCancel): Integer;
var
  I, Failed, Done: Integer;
  U: TUndoEntry;
  D: string;
begin
  FCancelled := False;
  Failed := 0;
  Done := 0;
  for I := Run.Items.Count - 1 downto 0 do begin
    if Assigned(OnCancel) and OnCancel() then begin
      FCancelled := True;
      Break;
    end;
    U := Run.Items[I];
    try
      if U.WasCopy then begin
        if FileExists(U.Target) then
          if not DeleteFile(U.Target) then
            raise Exception.Create(rsErrUndoCopyDel);
      end else begin
        if not DirectoryExists(ExtractFileDir(U.Source)) then
          ForceDirectories(ExtractFileDir(U.Source));
        if FileExists(U.Target) then begin
          if not RenameFile(U.Target, U.Source) then begin
            CopyFileContents(U.Target, U.Source);
            if not DeleteFile(U.Target) then
              raise Exception.Create(rsErrUndoTargetDel);
          end;
        end;
      end;
    except
      on E: Exception do begin
        Inc(Failed);
        if Log <> nil then
          Log.Add(Format(rsLogUndoFailFmt, [U.Target, E.Message]));
      end;
    end;
    Inc(Done);
    if Assigned(OnProgress) then
      OnProgress(Done, Run.Items.Count, U.Target);
  end;
  // 清理执行时新建、现已为空的目录（先深后浅，非空不动）
  if Run.CreatedDirs.Count > 0 then begin
    Run.CreatedDirs.CustomSort(@CompareDirDepth);
    for I := 0 to Run.CreatedDirs.Count - 1 do begin
      D := Run.CreatedDirs[I];
      if DirectoryExists(D) and DirIsEmpty(D) then
        if RemoveDir(D) then begin
          if Log <> nil then
            Log.Add(Format(rsLogDelEmptyUndoFmt, [D]));
        end;
    end;
  end;
  Result := Failed;
end;

end.
