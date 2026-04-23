program Phoevra;
uses
  Vcl.Forms,
  Phoevramain in 'Phoevramain.pas' {FormMain},
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
