program Phoevra;

uses
  Vcl.Forms,
  Vcl.Themes,
  Vcl.Styles,
  PhoevraMain in 'PhoevraMain.pas' {FormMain},
  PhoevraTypes in 'PhoevraTypes.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  TStyleManager.TrySetStyle('Glossy');
  Application.Run;
end.
