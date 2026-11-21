program octopus_archive;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // LCL widgetset
  Forms, Main, Organizer
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  ApplySavedLanguage;  // 在创建主窗体前应用语言，LFM 文本加载时即获得翻译
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
