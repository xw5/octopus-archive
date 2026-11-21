unit Main;

{ OctopusArchive 主界面：单窗口 + 三个功能标签页 + 预览 + 后台线程执行 }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, Grids, FileCtrl, IniFiles,
  Organizer;

type
  TWorkerKind = (wkPreview, wkExecute, wkUndo);

  { TWorkerThread - 后台线程：扫描/执行/撤销都在这里跑，避免卡死界面 }
  TWorkerThread = class(TThread)
  private
    FKind: TWorkerKind;
    FFeature: Integer;
    FOpt: TOrganizerOptions;
    FMaps: TFormatMaps;
    FRules: TRegexRules;
    FPlan: TPlanList;
    FRun: TRunRecord;
    FOwnsRun: Boolean;
    FLog: TStringList;
    FUndoFails: Integer;
    FNoOpCount: Integer;
    FTick: Integer;
    FProgCur, FProgTotal: Integer;
    FProgInfo: string;
    FCancelRequested: Boolean;
    FWasCancelled: Boolean;
    FError: string;
    procedure ProgressCb(Current, Total: Integer; const Info: string);
    function CancelCb: Boolean;
    procedure SyncProgress;
    procedure SyncFinish;
    procedure DoBuildPlan(Org: TOrganizer);
  protected
    procedure Execute; override;
  public
    constructor Create(AKind: TWorkerKind; AFeature: Integer;
      const AOpt: TOrganizerOptions; AMaps: TFormatMaps; ARules: TRegexRules;
      ARun: TRunRecord);
    destructor Destroy; override;
    procedure RequestCancel;
    function TakePlan: TPlanList;
    function TakeRun: TRunRecord;
    property Kind: TWorkerKind read FKind;
    property Opt: TOrganizerOptions read FOpt;
    property Plan: TPlanList read FPlan;
    property Run: TRunRecord read FRun;
    property UndoLog: TStringList read FLog;
    property UndoFails: Integer read FUndoFails;
    property NoOpCount: Integer read FNoOpCount;
    property WasCancelled: Boolean read FWasCancelled;
    property Error: string read FError;
  end;

  { TFormMain }
  TFormMain = class(TForm)
    btnBrowse: TButton;
    btnCancelRun: TButton;
    btnExecute: TButton;
    btnMapAdd: TButton;
    btnMapDel: TButton;
    btnOutBrowse: TButton;
    btnPreview: TButton;
    btnRuleAdd: TButton;
    btnRuleDel: TButton;
    btnRuleDown: TButton;
    btnRuleUp: TButton;
    btnUndo: TButton;
    chkDelEmpty: TCheckBox;
    chkFullname: TCheckBox;
    chkHidden: TCheckBox;
    chkIgnoreCase: TCheckBox;
    chkRecursive: TCheckBox;
    cmbConflict: TComboBox;
    cmbMode: TComboBox;
    dlgDir: TSelectDirectoryDialog;
    edtOut: TEdit;
    edtSrc: TEdit;
    gridMap: TStringGrid;
    gridPreview: TStringGrid;
    gridRules: TStringGrid;
    lblConflict: TLabel;
    lblFormatHelp: TLabel;
    lblFlattenHelp: TLabel;
    lblMode: TLabel;
    lblOut: TLabel;
    lblRegexHelp: TLabel;
    lblSrc: TLabel;
    lblStatus: TLabel;
    memoLog: TMemo;
    pbProgress: TProgressBar;
    pcMain: TPageControl;
    pnlActions: TPanel;
    pnlBottom: TPanel;
    pnlFmtTools: TPanel;
    pnlRegOpts: TPanel;
    pnlRegTools: TPanel;
    pnlRow1: TPanel;
    pnlRow2: TPanel;
    pnlRow3: TPanel;
    pnlStatus: TPanel;
    pnlTop: TPanel;
    tsFlatten: TTabSheet;
    tsFormat: TTabSheet;
    tsRegex: TTabSheet;
    procedure btnBrowseClick(Sender: TObject);
    procedure btnCancelRunClick(Sender: TObject);
    procedure btnExecuteClick(Sender: TObject);
    procedure btnMapAddClick(Sender: TObject);
    procedure btnMapDelClick(Sender: TObject);
    procedure btnOutBrowseClick(Sender: TObject);
    procedure btnPreviewClick(Sender: TObject);
    procedure btnRuleAddClick(Sender: TObject);
    procedure btnRuleDelClick(Sender: TObject);
    procedure btnRuleDownClick(Sender: TObject);
    procedure btnRuleUpClick(Sender: TObject);
    procedure btnUndoClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure GridResize(Sender: TObject);
    procedure gridPreviewPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
      AState: TGridDrawState);
  private
    FWorker: TWorkerThread;
    FCurrentPlan: TPlanList;
    FRuns: TRunList;
    FPreviewMap: array of Integer;
    FLastNoop: Integer;
    function ReadOptions(const ASrc: string): TOrganizerOptions;
    function ResolveOutDir: string;
    function GridToMaps: TFormatMaps;
    function GridToRules: TRegexRules;
    procedure LoadConfig;
    procedure SaveConfig;
    procedure StartWorker(AKind: TWorkerKind);
    procedure UpdateButtons;
    procedure ShowPreview(Plan: TPlanList);
    procedure AppendLog(const S: string);
  public
    procedure WorkerFinished;
  end;

var
  FormMain: TFormMain;

const
  FeatureNames: array[1..3] of string = ('按格式分组', '打平目录', '按正则分类');

implementation

{$R *.lfm}

{ TWorkerThread }

constructor TWorkerThread.Create(AKind: TWorkerKind; AFeature: Integer;
  const AOpt: TOrganizerOptions; AMaps: TFormatMaps; ARules: TRegexRules;
  ARun: TRunRecord);
begin
  inherited Create(True);  // 挂起创建，字段就绪后再启动
  FKind := AKind;
  FFeature := AFeature;
  FOpt := AOpt;
  FMaps := AMaps;
  FRules := ARules;
  FPlan := TPlanList.Create;
  FLog := TStringList.Create;
  if AKind = wkExecute then begin
    if ARun = nil then
      FRun := TRunRecord.Create('run')
    else
      FRun := ARun;
    FOwnsRun := True;
  end else begin
    FRun := ARun;
    FOwnsRun := False;
  end;
  Start;
end;

destructor TWorkerThread.Destroy;
begin
  FMaps.Free;
  FRules.Free;
  FPlan.Free;
  if FOwnsRun then
    FRun.Free;
  FLog.Free;
  inherited Destroy;
end;

procedure TWorkerThread.RequestCancel;
begin
  FCancelRequested := True;
end;

function TWorkerThread.TakePlan: TPlanList;
begin
  Result := FPlan;
  FPlan := nil;
end;

function TWorkerThread.TakeRun: TRunRecord;
begin
  Result := FRun;
  FRun := nil;
end;

procedure TWorkerThread.ProgressCb(Current, Total: Integer; const Info: string);
begin
  Inc(FTick);
  FProgCur := Current;
  FProgTotal := Total;
  FProgInfo := Info;
  // 小任务（≤200 项）每个事件都刷新；大任务每 50 个事件刷新一次，避免刷屏
  if (FTick mod 50 = 1) or (FProgTotal <= 200) then
    Synchronize(@SyncProgress);
end;

function TWorkerThread.CancelCb: Boolean;
begin
  Result := FCancelRequested or Terminated;
  if Result then
    FWasCancelled := True;
end;

procedure TWorkerThread.SyncProgress;
begin
  if not Assigned(FormMain) then
    Exit;
  if FProgTotal > 0 then begin
    FormMain.pbProgress.Max := FProgTotal;
    FormMain.pbProgress.Position := FProgCur;
    FormMain.lblStatus.Caption := Format('处理中 %d / %d：%s', [FProgCur, FProgTotal, FProgInfo]);
  end else begin
    FormMain.pbProgress.Max := 100;
    FormMain.pbProgress.Position := (FormMain.pbProgress.Position + 1) mod FormMain.pbProgress.Max;
    FormMain.lblStatus.Caption := '扫描中：' + FProgInfo;
  end;
end;

procedure TWorkerThread.SyncFinish;
begin
  if Assigned(FormMain) then
    FormMain.WorkerFinished;
end;

procedure TWorkerThread.DoBuildPlan(Org: TOrganizer);
begin
  case FFeature of
    1: Org.BuildPlanFeature1(FOpt, FMaps, FPlan, @ProgressCb, @CancelCb);
    2: Org.BuildPlanFlatten(FOpt, FPlan, @ProgressCb, @CancelCb);
    3: Org.BuildPlanRegex(FOpt, FRules, FPlan, @ProgressCb, @CancelCb);
  end;
  FNoOpCount := Org.NoOpCount;
end;

procedure TWorkerThread.Execute;
var
  Org: TOrganizer;
begin
  Org := TOrganizer.Create;
  try
    try
      case FKind of
        wkPreview:
          DoBuildPlan(Org);
        wkExecute:
          begin
            DoBuildPlan(Org);
            if not FWasCancelled then
              Org.ExecutePlan(FOpt, FPlan, FRun, FLog, @ProgressCb, @CancelCb);
          end;
        wkUndo:
          FUndoFails := Org.UndoRun(FRun, FLog, @ProgressCb, @CancelCb);
      end;
    except
      on E: Exception do
        FError := E.Message;
    end;
  finally
    Org.Free;
  end;
  try
    Synchronize(@SyncFinish);
  except
    // 应用正在关闭，忽略
  end;
end;

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  // 功能①映射表
  gridMap.ColCount := 2;
  gridMap.RowCount := 1;
  gridMap.FixedRows := 1;
  gridMap.FixedCols := 0;
  gridMap.ColWidths[0] := 420;
  gridMap.ColWidths[1] := 340;
  gridMap.Cells[0, 0] := '扩展名列表（逗号分隔，如 jpg,jpeg）';
  gridMap.Cells[1, 0] := '目标目录名（留空 = 默认第一个扩展名）';
  // 功能③规则表
  gridRules.ColCount := 2;
  gridRules.RowCount := 1;
  gridRules.FixedRows := 1;
  gridRules.FixedCols := 0;
  gridRules.ColWidths[0] := 420;
  gridRules.ColWidths[1] := 320;
  gridRules.Cells[0, 0] := '正则表达式（按顺序匹配，第一个命中生效）';
  gridRules.Cells[1, 0] := '目标目录名（留空 = 移到输出目录顶层）';
  // 预览表
  gridPreview.ColCount := 4;
  gridPreview.RowCount := 1;
  gridPreview.FixedRows := 1;
  gridPreview.FixedCols := 0;
  gridPreview.ColWidths[0] := 380;
  gridPreview.ColWidths[1] := 380;
  gridPreview.ColWidths[2] := 80;
  gridPreview.ColWidths[3] := 130;
  gridPreview.Cells[0, 0] := '源文件';
  gridPreview.Cells[1, 0] := '目标';
  gridPreview.Cells[2, 0] := '状态';
  gridPreview.Cells[3, 0] := '备注';
  // 表格观感：更高行距、隔行底色、主题化表头
  gridMap.DefaultRowHeight := 26;
  gridMap.RowHeights[0] := 28;
  gridMap.AlternateColor := TColor($F7F7F7);
  gridMap.TitleStyle := tsNative;
  gridRules.DefaultRowHeight := 26;
  gridRules.RowHeights[0] := 28;
  gridRules.AlternateColor := TColor($F7F7F7);
  gridRules.TitleStyle := tsNative;
  gridPreview.DefaultRowHeight := 24;
  gridPreview.RowHeights[0] := 28;
  gridPreview.AlternateColor := TColor($F7F7F7);
  gridPreview.TitleStyle := tsNative;
  // 说明文字弱化为灰色提示
  lblFormatHelp.Font.Color := clGrayText;
  lblFlattenHelp.Font.Color := clGrayText;
  lblRegexHelp.Font.Color := clGrayText;
  cmbMode.ItemIndex := 0;
  cmbConflict.ItemIndex := 0;
  pcMain.ActivePage := tsFormat;
  FRuns := TRunList.Create;
  LoadConfig;
  UpdateButtons;
  AppendLog('欢迎使用 OctopusArchive 文件整理工具');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  SaveConfig;
  if FWorker <> nil then begin
    FWorker.Terminate;
    FWorker.FreeOnTerminate := True;
    FWorker := nil;
  end;
  FreeAndNil(FCurrentPlan);
  FreeAndNil(FRuns);
  FormMain := nil;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FWorker <> nil then begin
    MessageDlg('任务进行中', '请先点击「取消」停止任务，再关闭窗口。',
      mtInformation, [mbOK], 0);
    FWorker.RequestCancel;
    CanClose := False;
  end else
    CanClose := True;
end;

procedure TFormMain.btnBrowseClick(Sender: TObject);
begin
  if edtSrc.Text <> '' then
    dlgDir.InitialDir := edtSrc.Text
  else
    dlgDir.InitialDir := ExtractFilePath(ParamStr(0));
  if dlgDir.Execute then
    edtSrc.Text := dlgDir.FileName;
end;

{ 输出目录规范化：留空返回 ''（= 跟随源目录）；
  相对路径（如 out 或 ..\backup）按源目录展开，返回值带尾部分隔符 }
function TFormMain.ResolveOutDir: string;
var
  S: string;
begin
  S := Trim(edtOut.Text);
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] = '"') then
    S := Trim(Copy(S, 2, Length(S) - 2));
  if S = '' then
    Exit('');
  if ((Length(S) >= 2) and (S[2] = ':')) or (Pos('\\', S) = 1) then
    Result := IncludeTrailingPathDelimiter(S)
  else
    Result := IncludeTrailingPathDelimiter(
      IncludeTrailingPathDelimiter(Trim(edtSrc.Text)) + S);
end;

procedure TFormMain.btnOutBrowseClick(Sender: TObject);
begin
  if DirectoryExists(ResolveOutDir) then
    dlgDir.InitialDir := ResolveOutDir
  else if DirectoryExists(Trim(edtSrc.Text)) then
    dlgDir.InitialDir := Trim(edtSrc.Text)
  else
    dlgDir.InitialDir := ExtractFilePath(ParamStr(0));
  if dlgDir.Execute then
    edtOut.Text := dlgDir.FileName;
end;

{ 让表格列按现有比例铺满整个客户区宽度，最后一列吸收取整余量 }
procedure DistributeGridCols(Grid: TStringGrid);
var
  I, Total, Avail, Acc: Integer;
  W: array of Integer;
begin
  Total := 0;
  for I := 0 to Grid.ColCount - 1 do
    Inc(Total, Grid.ColWidths[I]);
  if Total <= 0 then
    Exit;
  Avail := Grid.ClientWidth - Grid.GridLineWidth * (Grid.ColCount + 1);
  if Avail < 100 then
    Exit;
  SetLength(W, Grid.ColCount);
  Acc := 0;
  for I := 0 to Grid.ColCount - 2 do begin
    W[I] := Grid.ColWidths[I] * Avail div Total;
    if W[I] < 60 then
      W[I] := 60;
    Inc(Acc, W[I]);
  end;
  W[Grid.ColCount - 1] := Avail - Acc;
  if W[Grid.ColCount - 1] < 60 then
    W[Grid.ColCount - 1] := 60;
  for I := 0 to Grid.ColCount - 1 do
    Grid.ColWidths[I] := W[I];
end;

procedure TFormMain.FormShow(Sender: TObject);
var
  BaseH, I: Integer;
begin
  // 加大标签页：Win10/11 主题下标签高度只随字体增长（TCM_SETPADDING 无效），
  // 放大 PageControl 字体（约 12pt）；各页面字体固定为原字号，内容不受影响
  BaseH := pcMain.Font.Height;
  if BaseH >= 0 then
    BaseH := -12;  // 未取到有效字号时按系统默认 9pt
  pcMain.Font.Height := BaseH - 4;
  for I := 0 to pcMain.PageCount - 1 do begin
    pcMain.Pages[I].ParentFont := False;
    pcMain.Pages[I].Font.Height := BaseH;
  end;
  // 表格列宽铺满
  DistributeGridCols(gridMap);
  DistributeGridCols(gridRules);
  DistributeGridCols(gridPreview);
end;

procedure TFormMain.GridResize(Sender: TObject);
begin
  if Sender is TStringGrid then
    DistributeGridCols(TStringGrid(Sender));
end;

function TFormMain.ReadOptions(const ASrc: string): TOrganizerOptions;
begin
  Result.SourceDir := IncludeTrailingPathDelimiter(ASrc);
  Result.TargetDir := ResolveOutDir;
  if Result.TargetDir = '' then
    Result.TargetDir := Result.SourceDir;
  Result.Recursive := chkRecursive.Checked;
  Result.IncludeHidden := chkHidden.Checked;
  if cmbMode.ItemIndex = 1 then
    Result.Action := oaCopy
  else
    Result.Action := oaMove;
  Result.Conflict := TConflictMode(cmbConflict.ItemIndex);
  Result.DeleteEmptyDirs := chkDelEmpty.Checked;
  Result.FullnameMatch := chkFullname.Checked;
  Result.IgnoreCase := chkIgnoreCase.Checked;
  Result.ExcludeFile := Lowercase(ExtractFileName(ParamStr(0)));
end;

function TFormMain.GridToMaps: TFormatMaps;
var
  R: Integer;
  ExtList: string;
  Row: TFormatMapRow;
begin
  Result := TFormatMaps.Create;
  for R := 1 to gridMap.RowCount - 1 do begin
    ExtList := NormalizeExtList(gridMap.Cells[0, R]);
    if ExtList = '' then
      Continue;
    Row := TFormatMapRow.Create;
    Row.ExtList := ExtList;
    Row.Folder := Trim(gridMap.Cells[1, R]);
    Result.Add(Row);
  end;
end;

function TFormMain.GridToRules: TRegexRules;
var
  R: Integer;
  Pattern: string;
  Rule: TRegexRuleRow;
begin
  Result := TRegexRules.Create;
  for R := 1 to gridRules.RowCount - 1 do begin
    Pattern := Trim(gridRules.Cells[0, R]);
    if Pattern = '' then
      Continue;
    Rule := TRegexRuleRow.Create;
    Rule.Pattern := Pattern;
    Rule.Folder := Trim(gridRules.Cells[1, R]);
    Result.Add(Rule);
  end;
end;

procedure TFormMain.btnMapAddClick(Sender: TObject);
begin
  gridMap.RowCount := gridMap.RowCount + 1;
  gridMap.Row := gridMap.RowCount - 1;
  gridMap.Col := 0;
end;

procedure TFormMain.btnMapDelClick(Sender: TObject);
begin
  if gridMap.RowCount > 1 then begin
    if gridMap.Row < 1 then
      gridMap.Row := gridMap.RowCount - 1;
    gridMap.DeleteRow(gridMap.Row);
  end;
end;

procedure TFormMain.btnRuleAddClick(Sender: TObject);
begin
  gridRules.RowCount := gridRules.RowCount + 1;
  gridRules.Row := gridRules.RowCount - 1;
  gridRules.Col := 0;
end;

procedure TFormMain.btnRuleDelClick(Sender: TObject);
begin
  if gridRules.RowCount > 1 then begin
    if gridRules.Row < 1 then
      gridRules.Row := gridRules.RowCount - 1;
    gridRules.DeleteRow(gridRules.Row);
  end;
end;

procedure TFormMain.btnRuleUpClick(Sender: TObject);
var
  R: Integer;
begin
  R := gridRules.Row;
  if (R > 1) and (R < gridRules.RowCount) then begin
    gridRules.MoveColRow(False, R, R - 1);
    gridRules.Row := R - 1;
  end;
end;

procedure TFormMain.btnRuleDownClick(Sender: TObject);
var
  R: Integer;
begin
  R := gridRules.Row;
  if (R >= 1) and (R + 1 < gridRules.RowCount) then begin
    gridRules.MoveColRow(False, R, R + 1);
    gridRules.Row := R + 1;
  end;
end;

procedure TFormMain.btnPreviewClick(Sender: TObject);
begin
  StartWorker(wkPreview);
end;

procedure TFormMain.btnExecuteClick(Sender: TObject);
var
  Feature: Integer;
  Msg, OutD: string;
begin
  if FWorker <> nil then
    Exit;
  Feature := pcMain.ActivePageIndex + 1;
  OutD := ResolveOutDir;
  if OutD = '' then
    OutD := '与源目录相同'
  else
    OutD := ExcludeTrailingPathDelimiter(OutD);
  Msg := Format('确定执行「%s」？' + LineEnding + '模式：%s · 冲突处理：%s' + LineEnding +
    '源目录：%s' + LineEnding + '输出目录：%s',
    [FeatureNames[Feature], cmbMode.Text, cmbConflict.Text,
     ExcludeTrailingPathDelimiter(Trim(edtSrc.Text)), OutD]);
  if cmbConflict.ItemIndex = Ord(cmOverwrite) then
    Msg := Msg + LineEnding + LineEnding + '警告：同名文件将被覆盖，原内容无法恢复！';
  if MessageDlg('执行确认', Msg, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  StartWorker(wkExecute);
end;

procedure TFormMain.btnUndoClick(Sender: TObject);
begin
  if (FWorker <> nil) or (FRuns.Count = 0) then
    Exit;
  if MessageDlg('撤销确认', Format('撤销最近一次执行「%s」？',
      [FRuns[FRuns.Count - 1].Title]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    StartWorker(wkUndo);
end;

procedure TFormMain.btnCancelRunClick(Sender: TObject);
begin
  if FWorker <> nil then
    FWorker.RequestCancel;
end;

procedure TFormMain.StartWorker(AKind: TWorkerKind);
var
  Opt: TOrganizerOptions;
  Maps: TFormatMaps;
  Rules: TRegexRules;
  Run: TRunRecord;
  OwnRun: Boolean;
  Errs: TStringList;
  Feature: Integer;
  Src: string;
  OutD: string;
begin
  if FWorker <> nil then
    Exit;
  Src := Trim(edtSrc.Text);
  if (Src = '') or (not DirectoryExists(Src)) then begin
    MessageDlg('提示', '请先选择一个存在的源目录。', mtInformation, [mbOK], 0);
    Exit;
  end;
  OutD := ResolveOutDir;
  if (OutD <> '') and FileExists(ExcludeTrailingPathDelimiter(OutD)) then begin
    MessageDlg('提示', '输出目录指向的是一个已存在的文件，请重新选择。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  Feature := pcMain.ActivePageIndex + 1;
  Opt := ReadOptions(Src);
  Maps := nil;
  Rules := nil;
  Run := nil;
  OwnRun := False;
  try
    case Feature of
      1: Maps := GridToMaps;
      3:
        begin
          Rules := GridToRules;
          if Rules.Count = 0 then begin
            MessageDlg('提示', '请先在规则列表中添加至少一条正则规则。',
              mtInformation, [mbOK], 0);
            FreeAndNil(Rules);
            Exit;
          end;
          Errs := TStringList.Create;
          try
            ValidateRegexRules(Rules, Opt.IgnoreCase, Errs);
            if Errs.Count > 0 then begin
              MessageDlg('正则规则有误', Errs.Text, mtError, [mbOK], 0);
              FreeAndNil(Rules);
              Exit;
            end;
          finally
            Errs.Free;
          end;
        end;
    end;
    if AKind = wkExecute then begin
      Run := TRunRecord.Create(Format('%s（%s）', [FeatureNames[Feature],
        FormatDateTime('hh:nn:ss', Now)]));
      OwnRun := True;
    end else if AKind = wkUndo then begin
      // 撤销：复用最近一次执行的运行记录（所有权仍在 FRuns，线程不负责释放）
      if FRuns.Count = 0 then
        Exit;
      Run := FRuns[FRuns.Count - 1];
    end;
  except
    Maps.Free;
    Rules.Free;
    if OwnRun then
      Run.Free;
    raise;
  end;
  FWorker := TWorkerThread.Create(AKind, Feature, Opt, Maps, Rules, Run);
  UpdateButtons;
end;

procedure TFormMain.UpdateButtons;
var
  Running: Boolean;
begin
  Running := FWorker <> nil;
  btnPreview.Enabled := not Running;
  btnExecute.Enabled := not Running;
  btnUndo.Enabled := (not Running) and (FRuns.Count > 0);
  btnCancelRun.Enabled := Running;
  edtSrc.Enabled := not Running;
  btnBrowse.Enabled := not Running;
  edtOut.Enabled := not Running;
  btnOutBrowse.Enabled := not Running;
  pcMain.Enabled := not Running;
end;

procedure TFormMain.ShowPreview(Plan: TPlanList);
const
  MaxRows = 3000;
var
  I, Rows, Total, Pend, Over, Done, Skip, Fail: Integer;
  Item: TPlanItem;
  S: string;
begin
  gridPreview.BeginUpdate;
  try
    if Plan = nil then
      Rows := 0
    else
      Rows := Min(Plan.Count, MaxRows);
    gridPreview.RowCount := 1 + Rows;
    SetLength(FPreviewMap, Rows);
    for I := 0 to Rows - 1 do begin
      Item := Plan[I];
      FPreviewMap[I] := I;
      gridPreview.Cells[0, I + 1] := Item.Source;
      gridPreview.Cells[1, I + 1] := Item.Target;
      case Item.State of
        pisPending: if Item.DirConflict then S := '无法处理' else S := '待执行';
        pisSkipped: S := '跳过';
        pisDone: S := '完成';
        else S := '失败';
      end;
      gridPreview.Cells[2, I + 1] := S;
      if Item.State = pisFailed then
        gridPreview.Cells[3, I + 1] := Item.Note + ' ' + Item.ErrMsg
      else
        gridPreview.Cells[3, I + 1] := Item.Note;
    end;
  finally
    gridPreview.EndUpdate;
  end;
  Pend := 0;
  Over := 0;
  Done := 0;
  Skip := 0;
  Fail := 0;
  Total := 0;
  if Plan <> nil then begin
    Total := Plan.Count;
    for I := 0 to Plan.Count - 1 do
      case Plan[I].State of
        pisPending: begin Inc(Pend); if Plan[I].WillOverwrite then Inc(Over); end;
        pisDone: Inc(Done);
        pisSkipped: Inc(Skip);
        pisFailed: Inc(Fail);
      end;
  end;
  if Total = 0 then
    lblStatus.Caption := Format('没有需要处理的文件（已在目标位置 %d 项）', [FLastNoop])
  else
    lblStatus.Caption := Format(
      '共 %d 项：待执行 %d · 将覆盖 %d · 完成 %d · 跳过 %d · 失败 %d · 已在目标位置 %d',
      [Total, Pend, Over, Done, Skip, Fail, FLastNoop]);
end;

procedure TFormMain.AppendLog(const S: string);
begin
  memoLog.Lines.BeginUpdate;
  try
    memoLog.Lines.Add(Format('[%s] %s', [FormatDateTime('hh:nn:ss', Now), S]));
    while memoLog.Lines.Count > 1000 do
      memoLog.Lines.Delete(0);
  finally
    memoLog.Lines.EndUpdate;
  end;
end;

procedure TFormMain.WorkerFinished;
var
  W: TWorkerThread;
  Run: TRunRecord;
  I: Integer;
begin
  W := FWorker;
  FWorker := nil;
  if W = nil then
    Exit;
  try
    FLastNoop := W.NoOpCount;
    if W.Error <> '' then
      AppendLog('出错: ' + W.Error);
    case W.Kind of
      wkPreview:
        begin
          FreeAndNil(FCurrentPlan);
          FCurrentPlan := W.TakePlan;
          ShowPreview(FCurrentPlan);
        end;
      wkExecute:
        begin
          FreeAndNil(FCurrentPlan);
          FCurrentPlan := W.TakePlan;
          ShowPreview(FCurrentPlan);
          Run := W.TakeRun;
          if (Run <> nil) and (Run.Items.Count > 0) then begin
            FRuns.Add(Run);
            AppendLog(Format('「%s」执行完成，本次操作可撤销。', [Run.Title]));
          end else if Run <> nil then
            Run.Free;
          for I := 0 to W.UndoLog.Count - 1 do
            AppendLog(W.UndoLog[I]);
        end;
      wkUndo:
        begin
          for I := 0 to W.UndoLog.Count - 1 do
            AppendLog(W.UndoLog[I]);
          if W.Error = '' then begin
            AppendLog(Format('撤销完成，失败 %d 项。', [W.UndoFails]));
            if FRuns.Count > 0 then
              FRuns.Delete(FRuns.Count - 1);
            FreeAndNil(FCurrentPlan);
            ShowPreview(nil);
            lblStatus.Caption := '撤销完成';
          end else begin
            // 撤销出错时不弹出记录，保留可重试
            lblStatus.Caption := '撤销失败';
          end;
        end;
    end;
    if W.Error <> '' then
      MessageDlg('操作出错', W.Error, mtError, [mbOK], 0);
    if W.WasCancelled and (W.Kind <> wkUndo) then
      lblStatus.Caption := lblStatus.Caption + '（已取消）';
  finally
    // W 此刻仍阻塞在 Execute 尾声的 Synchronize 里；直接 Free 会触发
    // SysDestroy→WaitFor，与 Synchronize 互相等待导致死锁。
    // 改为交接给线程自行释放（Execute 返回后按 FreeOnTerminate 释放）。
    W.FreeOnTerminate := True;
    pbProgress.Position := 0;  // 完成后清零，不残留上次进度
    UpdateButtons;
  end;
end;

procedure TFormMain.gridPreviewPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
  AState: TGridDrawState);
var
  Idx: Integer;
begin
  if (ARow > 0) and (ARow - 1 < Length(FPreviewMap)) and (FCurrentPlan <> nil) then begin
    Idx := FPreviewMap[ARow - 1];
    if (Idx >= 0) and (Idx < FCurrentPlan.Count) then begin
      if FCurrentPlan[Idx].State = pisFailed then
        gridPreview.Canvas.Font.Color := clRed
      else if FCurrentPlan[Idx].WillOverwrite then
        gridPreview.Canvas.Font.Color := clMaroon;
    end;
  end;
end;

procedure TFormMain.LoadConfig;
var
  Ini: TIniFile;
  I, Cnt, P: Integer;
  S: string;
begin
  Ini := TIniFile.Create(ExtractFilePath(ParamStr(0)) + ConfigFileName);
  try
    edtSrc.Text := Ini.ReadString('Options', 'SourceDir', '');
    edtOut.Text := Ini.ReadString('Options', 'OutputDir', '');
    cmbMode.ItemIndex := Ini.ReadInteger('Options', 'Action', 0);
    cmbConflict.ItemIndex := Ini.ReadInteger('Options', 'Conflict', 0);
    chkRecursive.Checked := Ini.ReadBool('Options', 'Recursive', True);
    chkHidden.Checked := Ini.ReadBool('Options', 'IncludeHidden', False);
    chkDelEmpty.Checked := Ini.ReadBool('Flatten', 'DeleteEmptyDirs', False);
    chkFullname.Checked := Ini.ReadBool('Regex', 'FullnameMatch', True);
    chkIgnoreCase.Checked := Ini.ReadBool('Regex', 'IgnoreCase', True);
    // 功能①映射表
    Cnt := Ini.ReadInteger('FormatMap', 'Count', 0);
    gridMap.RowCount := 1;
    for I := 1 to Cnt do begin
      S := Ini.ReadString('FormatMap', 'Row' + IntToStr(I), '');
      P := Pos(#9, S);
      if P > 0 then begin
        gridMap.RowCount := gridMap.RowCount + 1;
        gridMap.Cells[0, gridMap.RowCount - 1] := Copy(S, 1, P - 1);
        gridMap.Cells[1, gridMap.RowCount - 1] := Copy(S, P + 1, MaxInt);
      end;
    end;
    // 功能③规则表
    Cnt := Ini.ReadInteger('RegexRules', 'Count', 0);
    gridRules.RowCount := 1;
    for I := 1 to Cnt do begin
      S := Ini.ReadString('RegexRules', 'Row' + IntToStr(I), '');
      P := Pos(#9, S);
      if P > 0 then begin
        gridRules.RowCount := gridRules.RowCount + 1;
        gridRules.Cells[0, gridRules.RowCount - 1] := Copy(S, 1, P - 1);
        gridRules.Cells[1, gridRules.RowCount - 1] := Copy(S, P + 1, MaxInt);
      end;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFormMain.SaveConfig;
var
  Ini: TIniFile;
  I: Integer;
begin
  if FormMain = nil then
    Exit;
  Ini := TIniFile.Create(ExtractFilePath(ParamStr(0)) + ConfigFileName);
  try
    Ini.WriteString('Options', 'SourceDir', edtSrc.Text);
    Ini.WriteString('Options', 'OutputDir', edtOut.Text);
    Ini.WriteInteger('Options', 'Action', cmbMode.ItemIndex);
    Ini.WriteInteger('Options', 'Conflict', cmbConflict.ItemIndex);
    Ini.WriteBool('Options', 'Recursive', chkRecursive.Checked);
    Ini.WriteBool('Options', 'IncludeHidden', chkHidden.Checked);
    Ini.WriteBool('Flatten', 'DeleteEmptyDirs', chkDelEmpty.Checked);
    Ini.WriteBool('Regex', 'FullnameMatch', chkFullname.Checked);
    Ini.WriteBool('Regex', 'IgnoreCase', chkIgnoreCase.Checked);
    Ini.WriteInteger('FormatMap', 'Count', gridMap.RowCount - 1);
    for I := 1 to gridMap.RowCount - 1 do
      Ini.WriteString('FormatMap', 'Row' + IntToStr(I),
        gridMap.Cells[0, I] + #9 + gridMap.Cells[1, I]);
    Ini.WriteInteger('RegexRules', 'Count', gridRules.RowCount - 1);
    for I := 1 to gridRules.RowCount - 1 do
      Ini.WriteString('RegexRules', 'Row' + IntToStr(I),
        gridRules.Cells[0, I] + #9 + gridRules.Cells[1, I]);
  finally
    Ini.Free;
  end;
end;

end.
