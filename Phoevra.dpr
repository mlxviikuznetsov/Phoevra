program Phoevra;
uses
  Vcl.Forms,
  PhoevraMain in 'PhoevraMain.pas' {FormMain},
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}
begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  TStyleManager.TrySetStyle('Glossy');
  Application.Run;
end.
