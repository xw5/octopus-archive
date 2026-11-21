unit Main;

{ OctopusArchive 主界面：单窗口 + 三个功能标签页 + 预览 + 后台线程执行 }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, Grids, FileCtrl, IniFiles, LCLType, LCLTranslator,
  Translations, LResources,
  {$IFDEF WINDOWS} Windows, {$ENDIF}
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
    cmbLang: TComboBox;
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
    lblLang: TLabel;
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
    procedure cmbLangChange(Sender: TObject);
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
    FLoadingLang: Boolean;    // 程序性设置 cmbLang.ItemIndex 时抑制 OnChange
    FComboLangIdx: Integer;   // ini 保存的语言选项（0=auto 1=zh 2=en），切换后恢复显示用
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
    procedure RefreshAfterLanguageSwitch;
  public
    procedure WorkerFinished;
  end;

var
  FormMain: TFormMain;

{ 读取 ini 中的语言设置并应用翻译。必须在主窗体创建之前调用（.lpr 中），
  这样窗体 LFM 文本流式加载时即可获得翻译；代码中的 resourcestring
  之后被引用时也已是译文的查找结果。 }
procedure ApplySavedLanguage;

implementation

{$R *.lfm}

{ 用户可见文本，resourcestring 供 i18n 翻译（英文见 languages/OctopusArchive.en.po） }
resourcestring
  // 状态栏与进度
  rsProcessingFmt  = '处理中 %d / %d：%s';
  rsScanningFmt    = '扫描中：%s';
  rsCancelledSfx   = '（已取消）';
  // 预览状态列
  rsStateBlocked   = '无法处理';
  rsStatePending   = '待执行';
  rsStateSkipped   = '跳过';
  rsStateDone      = '完成';
  rsStateFailed    = '失败';
  rsNoFilesFmt     = '没有需要处理的文件（已在目标位置 %d 项）';
  rsSummaryFmt     = '共 %d 项：待执行 %d · 将覆盖 %d · 完成 %d · 跳过 %d · 失败 %d · 已在目标位置 %d';
  // 表格列头
  rsMapColExt      = '扩展名列表（逗号分隔，如 jpg,jpeg）';
  rsMapColFolder   = '目标目录名（留空 = 默认第一个扩展名）';
  rsRuleColRegex   = '正则表达式（按顺序匹配，第一个命中生效）';
  rsRuleColFolder  = '目标目录名（留空 = 移到输出目录顶层）';
  rsColSource      = '源文件';
  rsColTarget      = '目标';
  rsColState       = '状态';
  rsColNote        = '备注';
  // 对话框
  rsTaskRunningTitle = '任务进行中';
  rsTaskRunningMsg   = '请先点击「取消」停止任务，再关闭窗口。';
  rsSameAsSource     = '与源目录相同';
  rsExecConfirmTitle = '执行确认';
  // 执行确认正文按行拆分（po 里 \n 展开为换行符，多行 msgid 难以精确匹配）
  rsExecConfirmHead  = '确定执行「%s」？';
  rsExecConfirmMode  = '模式：%s · 冲突处理：%s';
  rsExecConfirmSrc   = '源目录：%s';
  rsExecConfirmOut   = '输出目录：%s';
  rsOverwriteWarn    = '警告：同名文件将被覆盖，原内容无法恢复！';
  rsUndoConfirmTitle = '撤销确认';
  rsUndoConfirmFmt   = '撤销最近一次执行「%s」？';
  rsInfoTitle        = '提示';
  rsSelectSource     = '请先选择一个存在的源目录。';
  rsOutIsFile        = '输出目录指向的是一个已存在的文件，请重新选择。';
  rsAddRuleFirst     = '请先在规则列表中添加至少一条正则规则。';
  rsRegexErrTitle    = '正则规则有误';
  rsErrorTitle       = '操作出错';
  rsRunTitleFmt      = '%s（%s）';
  // 日志
  rsWelcome      = '欢迎使用 OctopusArchive 文件整理工具';
  rsLogErrorFmt  = '出错: %s';
  rsExecDoneFmt  = '「%s」执行完成，本次操作可撤销。';
  rsUndoDoneFmt  = '撤销完成，失败 %d 项。';
  rsUndoDone     = '撤销完成';
  rsUndoFailed   = '撤销失败';
  // 功能名
  rsFeature1     = '按格式分组';
  rsFeature2     = '打平目录';
  rsFeature3     = '按正则分类';
  // 下拉框选项（Items 在 FormCreate 里代码赋值，保证随语言切换）
  rsModeMove       = '移动';
  rsModeCopy       = '复制';
  rsConflictRename = '重命名加序号';
  rsConflictSkip   = '跳过';
  rsConflictOverwrite = '覆盖';
  rsLangAuto       = '跟随系统';

{ 功能名（原 FeatureNames 常量数组），按功能序号返回已翻译文本 }
function FeatureName(Feature: Integer): string;
begin
  case Feature of
    1: Result := rsFeature1;
    2: Result := rsFeature2;
  else
    Result := rsFeature3;
  end;
end;

{ ===== 内嵌英文翻译（zh 基准 ↔ en），支持运行时即时切换 =====
  英文 po 编译进 exe 资源 EN_PO（langres.rc → langres.res，源文件
  languages\OctopusArchive.en.po）。前向表 msgid=中文 → msgstr=英文；
  反向表由前向表翻转生成（msgid=英文 → msgstr=中文），供"英→中"切换。
  两条查找路径都可用：identifier 精确命中，或 msgid=当前文本回退
  （TPOFile.Translate 的既有行为，见 translations.pas）。 }

const
  EN_PO_RES_NAME = 'EN_PO';

var
  GPoZhEn, GPoEnZh: TPOFile;             // 前/反向 po（所有权在对应 translator）
  GTrZhEn, GTrEnZh: TPOTranslator;       // 挂到全局 LRSTranslator 的两个翻译器
  GActiveLang: string = 'zh';            // 当前生效语言（'zh' | 'en'）
  GAutoLang: string = 'zh';              // "跟随系统"解析出的语言，启动时算好

function EscapePo(const S: string): string;
begin
  // 与 tools/gen_po.py 的 esc() 一致
  Result := S.Replace('\', '\\').Replace('"', '\"');
end;

{ 由前向 po 生成反向 po 文本（msgid/msgstr 互换）并解析为 TPOFile }
function BuildReversePo(Fwd: TPOFile): TPOFile;
var
  I: Integer;
  It: TPOFileItem;
  Txt: string;
begin
  Txt := 'msgid ""' + sLineBreak + 'msgstr ""' + sLineBreak
    + '"Content-Type: text/plain; charset=UTF-8\\n"' + sLineBreak + sLineBreak;
  for I := 0 to Fwd.Items.Count - 1 do begin
    It := TPOFileItem(Fwd.Items[I]);
    if (It.Original = '') or (It.Translation = '') then Continue;
    Txt := Txt + '#: ' + It.IdentifierLow + sLineBreak
      + 'msgid "' + EscapePo(It.Translation) + '"' + sLineBreak
      + 'msgstr "' + EscapePo(It.Original) + '"' + sLineBreak + sLineBreak;
  end;
  Result := TPOFile.Create(True);
  Result.ReadPOText(Txt);
end;

{ 懒加载：从 exe 内嵌资源解析英文 po 并派生反向表（进程内仅一次） }
procedure EnsureTranslationTables;
var
  Res: TResourceStream;
begin
  if GPoZhEn <> nil then Exit;
  Res := TResourceStream.Create(HInstance, EN_PO_RES_NAME, RT_RCDATA);
  try
    GPoZhEn := TPOFile.Create(Res, False);   // Full=False：首条 header 不计条目
    GPoEnZh := BuildReversePo(GPoZhEn);
    GTrZhEn := TPOTranslator.Create(GPoZhEn);   // translator 接管 po 生命周期
    GTrEnZh := TPOTranslator.Create(GPoEnZh);
  finally
    Res.Free;
  end;
end;

procedure FreeTranslationState;
begin
  LRSTranslator := nil;              // 防 finalization 二次释放
  GTrZhEn.Free;  GTrZhEn := nil;     // translator.Destroy 连带释放其 po
  GTrEnZh.Free;  GTrEnZh := nil;
  GPoZhEn := nil;
  GPoEnZh := nil;
end;

{ 切换生效语言。启动阶段（FormMain=nil）只换 resourcestring 表与 LFM
  流式加载用的翻译器；窗体已存在时同步刷新界面（即时切换）。 }
procedure SetLanguageActive(const Lang: string);
begin
  if Lang = GActiveLang then Exit;
  EnsureTranslationTables;
  try
    if Lang = 'en' then begin
      TranslateResourceStrings(GPoZhEn);
      LRSTranslator := GTrZhEn;
    end else begin
      TranslateResourceStrings(GPoEnZh);
      LRSTranslator := GTrEnZh;
    end;
    GActiveLang := Lang;
  except
    // 内嵌资源缺失/损坏（异常构建）时保持原语言
  end;
  if FormMain <> nil then
    FormMain.RefreshAfterLanguageSwitch;
end;

{ 语言逻辑：ini [Options] Language = auto|zh|en。
  zh 是基准语言（源码内嵌中文），无需处理；
  en 走内嵌翻译（见上）；auto 按 Windows UI 语言：中文族 → 基准，其他 → 英文。
  单 exe 自带翻译，无需外部文件；调用时机在主窗体创建前（.lpr），
  这样窗体 LFM 文本流式加载时即获得翻译。 }
procedure ApplySavedLanguage;
var
  Ini: TIniFile;
  Lang: string;
begin
  // "跟随系统"只取决于系统语言本身，与 ini 里上次选了什么无关
  {$IFDEF WINDOWS}
  if (GetUserDefaultLangID and $3FF) = $04 then
    GAutoLang := 'zh'   // 中文系统用基准语言
  else
    GAutoLang := 'en';
  {$ELSE}
  GAutoLang := 'zh';
  {$ENDIF}
  Lang := 'auto';
  try
    Ini := TIniFile.Create(ExtractFilePath(ParamStr(0)) + ConfigFileName);
    try
      Lang := Ini.ReadString('Options', 'Language', 'auto');
    finally
      Ini.Free;
    end;
  except
    // ini 读取失败按"跟随系统"处理
  end;
  if Lang = 'auto' then
    Lang := GAutoLang;
  if Lang <> 'zh' then
    SetLanguageActive(Lang);
end;

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
    FormMain.lblStatus.Caption := Format(rsProcessingFmt, [FProgCur, FProgTotal, FProgInfo]);
  end else begin
    FormMain.pbProgress.Max := 100;
    FormMain.pbProgress.Position := (FormMain.pbProgress.Position + 1) mod FormMain.pbProgress.Max;
    FormMain.lblStatus.Caption := Format(rsScanningFmt, [FProgInfo]);
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
var
  W: Integer;
begin
  FLoadingLang := True;  // 程序性设置下拉框期间抑制 cmbLang.OnChange
  // 顶部三行标签统一列宽，使源目录/输出目录/模式后的输入控件左对齐
  // （按当前语言取三个标签的最宽者，中英文都紧凑对齐）
  W := Max(lblSrc.Canvas.TextWidth(lblSrc.Caption),
        Max(lblOut.Canvas.TextWidth(lblOut.Caption),
            lblMode.Canvas.TextWidth(lblMode.Caption))) + 8;
  lblSrc.AutoSize := False;
  lblOut.AutoSize := False;
  lblMode.AutoSize := False;
  lblSrc.Width := W;
  lblOut.Width := W;
  lblMode.Width := W;
  // 功能①映射表
  gridMap.ColCount := 2;
  gridMap.RowCount := 1;
  gridMap.FixedRows := 1;
  gridMap.FixedCols := 0;
  gridMap.ColWidths[0] := 420;
  gridMap.ColWidths[1] := 340;
  gridMap.Cells[0, 0] := rsMapColExt;
  gridMap.Cells[1, 0] := rsMapColFolder;
  // 功能③规则表
  gridRules.ColCount := 2;
  gridRules.RowCount := 1;
  gridRules.FixedRows := 1;
  gridRules.FixedCols := 0;
  gridRules.ColWidths[0] := 420;
  gridRules.ColWidths[1] := 320;
  gridRules.Cells[0, 0] := rsRuleColRegex;
  gridRules.Cells[1, 0] := rsRuleColFolder;
  // 预览表
  gridPreview.ColCount := 4;
  gridPreview.RowCount := 1;
  gridPreview.FixedRows := 1;
  gridPreview.FixedCols := 0;
  gridPreview.ColWidths[0] := 380;
  gridPreview.ColWidths[1] := 380;
  gridPreview.ColWidths[2] := 80;
  gridPreview.ColWidths[3] := 130;
  gridPreview.Cells[0, 0] := rsColSource;
  gridPreview.Cells[1, 0] := rsColTarget;
  gridPreview.Cells[2, 0] := rsColState;
  gridPreview.Cells[3, 0] := rsColNote;
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
  // 下拉框选项用代码赋值（LFM 集合项的运行时翻译不可靠），保证随语言切换
  cmbMode.Items.Clear;
  cmbMode.Items.Add(rsModeMove);
  cmbMode.Items.Add(rsModeCopy);
  cmbConflict.Items.Clear;
  cmbConflict.Items.Add(rsConflictRename);
  cmbConflict.Items.Add(rsConflictSkip);
  cmbConflict.Items.Add(rsConflictOverwrite);
  cmbLang.Items.Clear;
  cmbLang.Items.Add(rsLangAuto);
  cmbLang.Items.Add('中文');      // 语言名称不翻译
  cmbLang.Items.Add('English');
  cmbMode.ItemIndex := 0;
  cmbConflict.ItemIndex := 0;
  cmbLang.ItemIndex := 0;
  pcMain.ActivePage := tsFormat;
  FRuns := TRunList.Create;
  LoadConfig;
  FLoadingLang := False;
  UpdateButtons;
  AppendLog(rsWelcome);
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
    MessageDlg(rsTaskRunningTitle, rsTaskRunningMsg,
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
  // TCM_SETPADDING 在 Win10/11 视觉样式下宽高均无效，改用首尾空格拉开相邻标签
  // （在 LFM 翻译之后修改，不影响 po 匹配；防重入避免 OnShow 再次触发时叠加）
  for I := 0 to pcMain.PageCount - 1 do
    if Copy(pcMain.Pages[I].Caption, 1, 2) <> '  ' then
      pcMain.Pages[I].Caption := '  ' + pcMain.Pages[I].Caption + '  ';
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
    OutD := rsSameAsSource
  else
    OutD := ExcludeTrailingPathDelimiter(OutD);
  Msg := Format(rsExecConfirmHead, [FeatureName(Feature)]) + LineEnding
    + Format(rsExecConfirmMode, [cmbMode.Text, cmbConflict.Text]) + LineEnding
    + Format(rsExecConfirmSrc, [ExcludeTrailingPathDelimiter(Trim(edtSrc.Text))]) + LineEnding
    + Format(rsExecConfirmOut, [OutD]);
  if cmbConflict.ItemIndex = Ord(cmOverwrite) then
    Msg := Msg + LineEnding + LineEnding + rsOverwriteWarn;
  if MessageDlg(rsExecConfirmTitle, Msg, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  StartWorker(wkExecute);
end;

procedure TFormMain.btnUndoClick(Sender: TObject);
begin
  if (FWorker <> nil) or (FRuns.Count = 0) then
    Exit;
  if MessageDlg(rsUndoConfirmTitle, Format(rsUndoConfirmFmt,
      [FRuns[FRuns.Count - 1].Title]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    StartWorker(wkUndo);
end;

procedure TFormMain.btnCancelRunClick(Sender: TObject);
begin
  if FWorker <> nil then
    FWorker.RequestCancel;
end;

procedure TFormMain.cmbLangChange(Sender: TObject);
begin
  if FLoadingLang then Exit;  // 程序性设置（FormCreate/LoadConfig/刷新）不触发切换
  // 记录用户选择（刷新时恢复显示用；退出时 SaveConfig 也按此写 ini）
  FComboLangIdx := cmbLang.ItemIndex;
  // 即时切换：resourcestring 表 + 已创建窗体的 LFM 属性 + 代码赋值文本一并刷新
  case cmbLang.ItemIndex of
    1: SetLanguageActive('zh');
    2: SetLanguageActive('en');
  else
    SetLanguageActive(GAutoLang);  // 跟随系统 → 启动时解析的系统语言
  end;
end;

{ 语言即时切换后的界面刷新。LRSTranslator.UpdateTranslation 覆盖 published
  字符串属性（Caption/Text/TextHint）；以下代码赋值的文本不在其覆盖范围，
  需在此重刷；预览网格从内存中的计划重渲染（不重新扫描）。 }
procedure TFormMain.RefreshAfterLanguageSwitch;
var
  I: Integer;
begin
  // 标签页 caption 带 FormShow 加的两空格 padding，先去掉才能按 msgid 匹配
  for I := 0 to pcMain.PageCount - 1 do
    pcMain.Pages[I].Caption := Trim(pcMain.Pages[I].Caption);
  if LRSTranslator is TUpdateTranslator then
    TUpdateTranslator(LRSTranslator).UpdateTranslation(Self);
  // 重新补标签页间距 padding（同 FormShow）
  for I := 0 to pcMain.PageCount - 1 do
    pcMain.Pages[I].Caption := '  ' + pcMain.Pages[I].Caption + '  ';
  // 下拉框选项（rs* 已是新语言的查找结果；语言名本身不翻译）
  I := cmbMode.ItemIndex;
  cmbMode.Items.Clear;
  cmbMode.Items.Add(rsModeMove);
  cmbMode.Items.Add(rsModeCopy);
  cmbMode.ItemIndex := I;
  I := cmbConflict.ItemIndex;
  cmbConflict.Items.Clear;
  cmbConflict.Items.Add(rsConflictRename);
  cmbConflict.Items.Add(rsConflictSkip);
  cmbConflict.Items.Add(rsConflictOverwrite);
  cmbConflict.ItemIndex := I;
  I := cmbLang.ItemIndex;
  cmbLang.Items.Clear;
  cmbLang.Items.Add(rsLangAuto);
  cmbLang.Items.Add('中文');
  cmbLang.Items.Add('English');
  cmbLang.ItemIndex := FComboLangIdx;
  // 表格列头
  gridMap.Cells[0, 0] := rsMapColExt;
  gridMap.Cells[1, 0] := rsMapColFolder;
  gridRules.Cells[0, 0] := rsRuleColRegex;
  gridRules.Cells[1, 0] := rsRuleColFolder;
  gridPreview.Cells[0, 0] := rsColSource;
  gridPreview.Cells[1, 0] := rsColTarget;
  gridPreview.Cells[2, 0] := rsColState;
  gridPreview.Cells[3, 0] := rsColNote;
  // 预览网格与状态栏摘要重渲染（无计划时保持"就绪"，其 Caption 由
  // UpdateTranslation 翻译）
  if FCurrentPlan <> nil then
    ShowPreview(FCurrentPlan);
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
    MessageDlg(rsInfoTitle, rsSelectSource, mtInformation, [mbOK], 0);
    Exit;
  end;
  OutD := ResolveOutDir;
  if (OutD <> '') and FileExists(ExcludeTrailingPathDelimiter(OutD)) then begin
    MessageDlg(rsInfoTitle, rsOutIsFile, mtInformation, [mbOK], 0);
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
            MessageDlg(rsInfoTitle, rsAddRuleFirst,
              mtInformation, [mbOK], 0);
            FreeAndNil(Rules);
            Exit;
          end;
          Errs := TStringList.Create;
          try
            ValidateRegexRules(Rules, Opt.IgnoreCase, Errs);
            if Errs.Count > 0 then begin
              MessageDlg(rsRegexErrTitle, Errs.Text, mtError, [mbOK], 0);
              FreeAndNil(Rules);
              Exit;
            end;
          finally
            Errs.Free;
          end;
        end;
    end;
    if AKind = wkExecute then begin
      Run := TRunRecord.Create(Format(rsRunTitleFmt, [FeatureName(Feature),
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
        pisPending: if Item.DirConflict then S := rsStateBlocked else S := rsStatePending;
        pisSkipped: S := rsStateSkipped;
        pisDone: S := rsStateDone;
        else S := rsStateFailed;
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
    lblStatus.Caption := Format(rsNoFilesFmt, [FLastNoop])
  else
    lblStatus.Caption := Format(rsSummaryFmt,
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
      AppendLog(Format(rsLogErrorFmt, [W.Error]));
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
            AppendLog(Format(rsExecDoneFmt, [Run.Title]));
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
            AppendLog(Format(rsUndoDoneFmt, [W.UndoFails]));
            if FRuns.Count > 0 then
              FRuns.Delete(FRuns.Count - 1);
            FreeAndNil(FCurrentPlan);
            ShowPreview(nil);
            lblStatus.Caption := rsUndoDone;
          end else begin
            // 撤销出错时不弹出记录，保留可重试
            lblStatus.Caption := rsUndoFailed;
          end;
        end;
    end;
    if W.Error <> '' then
      MessageDlg(rsErrorTitle, W.Error, mtError, [mbOK], 0);
    if W.WasCancelled and (W.Kind <> wkUndo) then
      lblStatus.Caption := lblStatus.Caption + rsCancelledSfx;
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
    // 语言（auto/zh/en；与 ApplySavedLanguage 的取值一致）
    S := Ini.ReadString('Options', 'Language', 'auto');
    if S = 'en' then
      cmbLang.ItemIndex := 2
    else if S = 'zh' then
      cmbLang.ItemIndex := 1
    else
      cmbLang.ItemIndex := 0;
    FComboLangIdx := cmbLang.ItemIndex;
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
    case cmbLang.ItemIndex of
      2: Ini.WriteString('Options', 'Language', 'en');
      1: Ini.WriteString('Options', 'Language', 'zh');
    else
      Ini.WriteString('Options', 'Language', 'auto');
    end;
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

initialization
finalization
  // 释放内嵌翻译的 po/translator（translator 连带释放其 po）；
  // 先清 LRSTranslator，避免 lcltranslator.finalization 二次释放
  FreeTranslationState;
end.
