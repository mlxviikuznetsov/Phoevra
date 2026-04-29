unit PhoevraMain;
{ Phoevra -- MIDI synthesizer.
  Parses a MIDI file, renders notes to a 16-bit PCM buffer
  with sine wave synthesis and ADSR envelope, then plays or exports to WAV.
  Also supprots simple live keyboard playback. }

interface

uses
  Winapi.Windows,
  Winapi.MMSystem,
  System.SysUtils,
  System.Types,
  System.Math,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  PhoevraTypes;

type
  TFormMain = class(TForm)
    // UI controls
    pnlTop        : TPanel;
    btnOpenMidi   : TButton;
    btnPlay       : TButton;
    btnStop       : TButton;
    btnExportWAV  : TButton;
    btnLive       : TButton;
    lblFile       : TLabel;
    lblStatus     : TLabel;
    pnlSettings: TPanel;
    lblADSRTitle  : TLabel;
    lblA : TLabel;  tbAttack  : TTrackBar;  lblAVal : TLabel;
    lblD : TLabel;  tbDecay   : TTrackBar;  lblDVal : TLabel;
    lblS : TLabel;  tbSustain : TTrackBar;  lblSVal : TLabel;
    lblR : TLabel;  tbRelease : TTrackBar;  lblRVal : TLabel;

    pbWave        : TPaintBox;
    tmPlayback    : TTimer;
    mLog          : TMemo;
    dlgOpen       : TOpenDialog;
    dlgSave       : TSaveDialog;
    rgShape: TRadioGroup;
    pnlBottom: TPanel;
    btnSaveLog: TButton;
    pnlSettingsButtons: TPanel;
    btnApplyADSR: TButton;
    btnSavePreset: TButton;
    btnLoadPreset: TButton;

    // UI event handlers
    procedure btnOpenMidiClick(Sender: TObject);
    procedure btnPlayClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnExportWAVClick(Sender: TObject);
    procedure btnLiveClick(Sender: TObject);
    procedure btnSavePresetClick(Sender: TObject);
    procedure btnLoadPresetClick(Sender: TObject);
    procedure btnApplyADSRClick(Sender: TObject);
    procedure btnSaveLogClick(Sender: TObject);
    procedure tbChange(Sender: TObject);
    procedure rgShapeClick(Sender: TObject);
    procedure tmPlaybackTimer(Sender: TObject);
    procedure pbWavePaint(Sender: TObject);
    procedure pbWaveMouseDown(Sender: TObject; Button: TMouseButton;
                              Shift: TShiftState; X, Y: Integer);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);

  private
    FEvents         : TMidiEventList;
    FNotes          : TNoteList;
    FPCMBuffer      : array of SmallInt;
    FPCMLength      : Integer;
    FWaveOut        : HWAVEOUT;
    FWaveHeader     : TWAVEHDR;
    FSeekSample     : Integer;
    FPlaybackSample : Integer;
    FMidiLoaded     : Boolean;
    FWaveBitmap     : TBitmap;

    // Live mode
    FLiveNotes  : TLiveNoteList;
    FLiveSynth  : TLiveSynthThread;
    FLiveMode   : Boolean;
    FWaveShape  : TWaveShape;

    // Integer copies of trackbar positions
    FAttPos, FDecPos, FSusPos, FRelPos : Integer;

    // Core algorithms
    function  ReadVarLen(const ABuf: array of Byte;
                         var APos: Integer): LongWord;
    function  ParseMidiFile(const AFileName: string): Boolean;
    function  NoteToFreq(ANote: Byte): Double;
    function  GenerateWave(AShape: TWaveShape; APhase, AAmp: Double): Double;
    function  ApplyADSR(ASampleIdx, ATotalSamples: Integer): Double;
    procedure RenderToBuffer;

    // Helpers
    procedure BuildNoteList;
    procedure StopPlayback;
    procedure StopLive;
    procedure RenderWaveToBitmap;
    procedure DrawWave;
    procedure Log(const S: string);
    function  ReadUInt32BE(const B: array of Byte; P: Integer): LongWord;
    function  ReadUInt16BE(const B: array of Byte; P: Integer): Word;
    function  VKeyToMidi(AVK: Word; out AMidi: Byte): Boolean;
    procedure SyncTrackbarCache;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}



{ Core algorithms }

// Variable-length quantity decoding
function TFormMain.ReadVarLen(const ABuf: array of Byte;
                               var APos: Integer): LongWord;
var B: Byte;
begin
  Result := 0;
  repeat
    if APos >= Length(ABuf) then Break;
    B := ABuf[APos];
    Inc(APos);
    Result := (Result shl 7) or (B and $7F);
  until (B and $80) = 0;
end;

// MIDI file parser
function TFormMain.ParseMidiFile(const AFileName: string): Boolean;
var
  F            : file of Byte;
  Buf          : array of Byte;
  FileLen      : Integer;
  i, Pos       : Integer;
  Fmt          : Word;
  NumTracks    : Word;
  TicksPerBeat : Word;
  Tag          : array[0..3] of Char;
  ChunkLen     : LongWord;
  TrackEnd     : Integer;
  Tempo        : LongWord;
  AbsSec       : Double;
  Delta        : LongWord;
  Status       : Byte;
  LastStatus   : Byte;
  EvType       : Byte;
  Channel      : Byte;
  P1, P2       : Byte;
  Ev           : TMidiEvent;
begin
  Result := False;
  FEvents.Clear;

  AssignFile(F, AFileName);
  try
    Reset(F);
    FileLen := FileSize(F);
    if FileLen < 14 then begin Log('File too small'); Exit; end;
    SetLength(Buf, FileLen);
    for i := 0 to FileLen - 1 do Read(F, Buf[i]);
  finally
    CloseFile(F);
  end;

  // Process MThd chunk
  if (Buf[0] <> Ord('M')) or (Buf[1] <> Ord('T'))
  or (Buf[2] <> Ord('h')) or (Buf[3] <> Ord('d')) then
  begin
    Log('Not a MIDI file -- missing MThd signature');
    Exit;
  end;

  Pos          := 8;
  Fmt          := ReadUInt16BE(Buf, Pos); Inc(Pos, 2);
  NumTracks    := ReadUInt16BE(Buf, Pos); Inc(Pos, 2);
  TicksPerBeat := ReadUInt16BE(Buf, Pos); Inc(Pos, 2);
  if TicksPerBeat = 0 then TicksPerBeat := 480;

  Log(Format('MIDI: format=%d  tracks=%d  ticks/beat=%d',
      [Fmt, NumTracks, TicksPerBeat]));

  Tempo      := 500000;
  LastStatus := 0;

  while Pos + 8 <= Length(Buf) do
  begin
    Tag[0] := Char(Buf[Pos]);   Tag[1] := Char(Buf[Pos+1]);
    Tag[2] := Char(Buf[Pos+2]); Tag[3] := Char(Buf[Pos+3]);
    Inc(Pos, 4);
    ChunkLen := ReadUInt32BE(Buf, Pos); Inc(Pos, 4);
    TrackEnd := Pos + Integer(ChunkLen);

    // Process MTrk chunks
    if (Tag[0]<>'M') or (Tag[1]<>'T') or (Tag[2]<>'r') or (Tag[3]<>'k') then
    begin
      Pos := TrackEnd; Continue;
    end;

    AbsSec := 0;
    while Pos < TrackEnd do
    begin
      Delta  := ReadVarLen(Buf, Pos);
      AbsSec := AbsSec + Delta * (Tempo / TicksPerBeat) / 1000000.0;
      if Pos >= TrackEnd then Break;

      if (Buf[Pos] and $80) <> 0 then
      begin
        Status := Buf[Pos]; LastStatus := Status; Inc(Pos);
      end
      else
        Status := LastStatus;

      EvType  := Status and $F0;
      Channel := Status and $0F;

      if EvType = $80 then
      begin
        if Pos + 1 >= TrackEnd then Break;
        P1 := Buf[Pos]; Inc(Pos); P2 := Buf[Pos]; Inc(Pos);
        FillChar(Ev, SizeOf(Ev), 0);
        Ev.TimeSeconds := AbsSec; Ev.EventType := metNoteOff;
        Ev.Note := P1; Ev.Velocity := P2; Ev.Channel := Channel;
        FEvents.Add(Ev);
      end
      else if EvType = $90 then
      begin
        if Pos + 1 >= TrackEnd then Break;
        P1 := Buf[Pos]; Inc(Pos); P2 := Buf[Pos]; Inc(Pos);
        FillChar(Ev, SizeOf(Ev), 0);
        Ev.TimeSeconds := AbsSec; Ev.Channel := Channel;
        Ev.Note := P1; Ev.Velocity := P2;
        if P2 = 0 then Ev.EventType := metNoteOff
        else            Ev.EventType := metNoteOn;
        FEvents.Add(Ev);
      end
      else if Status = $FF then
      begin
        if Pos >= TrackEnd then Break;
        P1 := Buf[Pos]; Inc(Pos);
        ChunkLen := ReadVarLen(Buf, Pos);
        if (P1 = $51) and (Integer(ChunkLen) >= 3) and (Pos + 2 < TrackEnd) then
        begin
          Tempo := (LongWord(Buf[Pos]) shl 16)
                 or (LongWord(Buf[Pos+1]) shl 8)
                 or  LongWord(Buf[Pos+2]);
          FillChar(Ev, SizeOf(Ev), 0);
          Ev.TimeSeconds := AbsSec; Ev.EventType := metTempo; Ev.Tempo := Tempo;
          FEvents.Add(Ev);
          Log(Format('Tempo changed: %.1f BPM', [60000000.0 / Tempo]));
        end;
        Inc(Pos, Integer(ChunkLen));
      end
      else if EvType in [$A0, $B0, $E0] then Inc(Pos, 2)
      else if EvType in [$C0, $D0]      then Inc(Pos, 1)
      else Inc(Pos);
    end;

    Pos := TrackEnd;
  end;

  Log(Format('Events parsed: %d', [FEvents.Count]));
  Result := FEvents.Count > 0;
end;

// Convert MIDI note number to frequency (equal temperament)
function TFormMain.NoteToFreq(ANote: Byte): Double;
begin
  Result := 440.0 * Power(2.0, (Integer(ANote) - 69) / 12.0);
end;

// Returns one sample of the selected waveform at given phase
function TFormMain.GenerateWave(AShape: TWaveShape;
                                 APhase, AAmp: Double): Double;
var T: Double;
begin
  case AShape of
    wsSquare:
      if Sin(APhase) >= 0.0 then Result := AAmp else Result := -AAmp;
    wsSawtooth:
      Result := AAmp * (1.0 - APhase / Pi);
    wsTriangle:
      begin
        T := APhase / Pi;
        if T > 1.0 then T := 2.0 - T;
        Result := AAmp * (T * 2.0 - 1.0);
      end;
  else
    Result := AAmp * Sin(APhase);
  end;
end;

// Computes ADSR envelope value for a given sample position
function TFormMain.ApplyADSR(ASampleIdx, ATotalSamples: Integer): Double;
var
  A, D, R  : Integer;
  S        : Double;
  i, RStart: Integer;
begin
  A      := Round(tbAttack.Position  / 100.0 * SAMPLE_RATE);
  D      := Round(tbDecay.Position   / 100.0 * SAMPLE_RATE);
  S      :=       tbSustain.Position / 100.0;
  R      := Round(tbRelease.Position / 100.0 * SAMPLE_RATE);
  i      := ASampleIdx;
  RStart := Max(A + D, ATotalSamples - R);

  if i < A then
  begin
    if A > 0 then Result := i / A else Result := 1.0;
  end
  else if i < A + D then
  begin
    if D > 0 then Result := 1.0 - (1.0 - S) * ((i - A) / D)
    else           Result := S;
  end
  else if i < RStart then
    Result := S
  else
  begin
    if R > 0 then Result := S * (1.0 - (i - RStart) / R)
    else          Result := 0.0;
  end;

  if Result < 0.0 then Result := 0.0;
  if Result > 1.0 then Result := 1.0;
end;

// Render all notes into a 16-bit PCM buffer
procedure TFormMain.RenderToBuffer;
var
  Node      : PNoteNode;
  MixBuf    : array of Double;
  TotalSmp  : Integer;
  StartSmp  : Integer;
  EndSmp    : Integer;
  NoteSmp   : Integer;
  VelScale  : Double;
  MaxVal    : Double;
  FadeLen   : Integer;
  FadeCoeff : Double;
  Phase     : Double;
  PhStep    : Double;
  i         : Integer;
begin
  if FNotes.Count = 0 then
  begin
    Log('No notes to render'); Exit;
  end;

  TotalSmp := 0;
  Node := FNotes.Head;
  while Node <> nil do
  begin
    EndSmp := Round(Node^.Data.EndSec * SAMPLE_RATE) + SAMPLE_RATE;
    if EndSmp > TotalSmp then TotalSmp := EndSmp;
    Node := Node^.Next;
  end;

  SetLength(MixBuf, TotalSmp);
  for i := 0 to TotalSmp - 1 do MixBuf[i] := 0;

  // Mix all notes into MixBuf with per-note ADSR + fade
  Node := FNotes.Head;
  while Node <> nil do
  begin
    StartSmp := Round(Node^.Data.StartSec * SAMPLE_RATE);
    EndSmp   := Round(Node^.Data.EndSec   * SAMPLE_RATE);
    NoteSmp  := EndSmp - StartSmp;
    if NoteSmp > 0 then
    begin
      VelScale := Node^.Data.Velocity / 127.0;
      FadeLen  := Min(FADE_SAMPLES, NoteSmp div 2);
      PhStep   := 2.0 * Pi * Node^.Data.Frequency / SAMPLE_RATE;
      Phase    := 0.0;
      for i := 0 to NoteSmp - 1 do
      begin
        if StartSmp + i >= TotalSmp then Break;
        if i < FadeLen then
          FadeCoeff := i / FadeLen
        else if i >= NoteSmp - FadeLen then
          FadeCoeff := (NoteSmp - 1 - i) / FadeLen
        else
          FadeCoeff := 1.0;
        MixBuf[StartSmp + i] := MixBuf[StartSmp + i]
          + GenerateWave(FWaveShape, Phase, 1.0)
          * ApplyADSR(i, NoteSmp)
          * VelScale
          * FadeCoeff;
        Phase := Phase + PhStep;
        if Phase >= 2.0 * Pi then Phase := Phase - 2.0 * Pi;
      end;
    end;
    Node := Node^.Next;
  end;

  MaxVal := 0;
  for i := 0 to TotalSmp - 1 do
    if Abs(MixBuf[i]) > MaxVal then MaxVal := Abs(MixBuf[i]);

  SetLength(FPCMBuffer, TotalSmp);
  FPCMLength := TotalSmp;
  for i := 0 to TotalSmp - 1 do
  begin
    if MaxVal > 0 then
      FPCMBuffer[i] := Round(MixBuf[i] / MaxVal * MAX_AMPLITUDE)
    else
      FPCMBuffer[i] := 0;
  end;

  FSeekSample     := 0;
  FPlaybackSample := 0;
  RenderWaveToBitmap;

  Log(Format('Render done: %d samples (%.2f s)',
      [FPCMLength, FPCMLength / SAMPLE_RATE]));
end;

{ Helpers }

// Matches each NoteOff with its earliest unused NoteOn on the same note
// and channel, producing a list of TActiveNote records
procedure TFormMain.BuildNoteList;
var
  Node, OnNode : PMidiEventNode;
  Note         : TActiveNote;
begin
  FNotes.Clear;
  Node := FEvents.Head;
  while Node <> nil do
  begin
    if Node^.Data.EventType = metNoteOff then
    begin
      OnNode := FEvents.Head;
      while OnNode <> nil do
      begin
        if (OnNode^.Data.EventType    = metNoteOn)
        and (OnNode^.Data.Note        = Node^.Data.Note)
        and (OnNode^.Data.Channel     = Node^.Data.Channel)
        and (OnNode^.Data.TimeSeconds < Node^.Data.TimeSeconds) then
        begin
          FillChar(Note, SizeOf(Note), 0);
          Note.Note      := OnNode^.Data.Note;
          Note.Frequency := NoteToFreq(OnNode^.Data.Note);
          Note.StartSec  := OnNode^.Data.TimeSeconds;
          Note.EndSec    := Node^.Data.TimeSeconds;
          Note.Velocity  := OnNode^.Data.Velocity;
          FNotes.Add(Note);
          OnNode^.Data.TimeSeconds := 1e18;
          Break;
        end;
        OnNode := OnNode^.Next;
      end;
    end;
    Node := Node^.Next;
  end;
  Log(Format('Notes to render: %d', [FNotes.Count]));
end;

procedure TFormMain.StopPlayback;
begin
  tmPlayback.Enabled := False;
  if FWaveOut <> 0 then
  begin
    waveOutReset(FWaveOut);
    waveOutUnprepareHeader(FWaveOut, @FWaveHeader, SizeOf(FWaveHeader));
    waveOutClose(FWaveOut);
    FWaveOut := 0;
  end;
end;

procedure TFormMain.StopLive;
begin
  if not FLiveMode then Exit;
  FLiveMode := False;
  if Assigned(FLiveSynth) then
  begin
    FLiveSynth.Terminate;
    FLiveSynth.WaitFor;
    FreeAndNil(FLiveSynth);
  end;
  FLiveNotes.Clear;
  btnLive.Caption   := '◉ Live';
  if FPCMLength = 0 then
    lblStatus.Caption := ''
  else
    lblStatus.Caption := '◻ Ready';
end;

// Renders the static waveform shape onto FWaveBitmap once after render.
// Called only when PCM data changes, not every frame
procedure TFormMain.RenderWaveToBitmap;
var
  x, y      : Integer;
  Step, Val : Double;
  PW, PH    : Integer;
begin
  PW := pbWave.Width;
  PH := pbWave.Height;
  if (PW <= 0) or (PH <= 0) then Exit;

  FWaveBitmap.Width  := PW;
  FWaveBitmap.Height := PH;

  with FWaveBitmap.Canvas do
  begin
    Brush.Color := $1A1A1A;
    Brush.Style := bsSolid;
    FillRect(Rect(0, 0, PW, PH));

    Pen.Color := $444444;
    Pen.Width := 1;
    MoveTo(0, PH div 2);
    LineTo(PW, PH div 2);

    if FPCMLength = 0 then Exit;

    Pen.Color := $FF7733;
    Step := FPCMLength / PW;
    for x := 0 to PW - 1 do
    begin
      Val := FPCMBuffer[Round(x * Step)] / MAX_AMPLITUDE;
      y   := Round((PH / 2) * (1.0 - Val));
      y   := Max(0, Min(PH - 1, y));
      if x = 0 then MoveTo(x, y) else LineTo(x, y);
    end;
  end;
end;

// Draws the oscilloscope. The static wave comes from FWaveBitmap.
// Only the playhead line is re-drawn each frame
procedure TFormMain.DrawWave;
var
  PW, PH : Integer;
  PlayX  : Integer;
  C      : TCanvas;
begin
  C  := pbWave.Canvas;
  PW := pbWave.Width;
  PH := pbWave.Height;
  if (PW <= 0) or (PH <= 0) then Exit;

  if (FWaveBitmap.Width <> PW) or (FWaveBitmap.Height <> PH) then
    RenderWaveToBitmap;

  // Copy static background in one BitBlt
  BitBlt(C.Handle, 0, 0, PW, PH, FWaveBitmap.Canvas.Handle, 0, 0, SRCCOPY);

  if FPCMLength = 0 then Exit;

  PlayX := Round(FPlaybackSample / FPCMLength * PW);
  PlayX := Max(0, Min(PW - 1, PlayX));

  C.Pen.Color := $FFFFFF;
  C.Pen.Width := 1;
  C.MoveTo(PlayX, 0);
  C.LineTo(PlayX, PH);
end;

procedure TFormMain.Log(const S: string);
begin
  mLog.Lines.Add(S);
end;

// Big-endian read helpers
function TFormMain.ReadUInt32BE(const B: array of Byte; P: Integer): LongWord;
begin
  Result := (LongWord(B[P])   shl 24) or (LongWord(B[P+1]) shl 16)
          or (LongWord(B[P+2]) shl  8) or  LongWord(B[P+3]);
end;

function TFormMain.ReadUInt16BE(const B: array of Byte; P: Integer): Word;
begin
  Result := (Word(B[P]) shl 8) or Word(B[P+1]);
end;

// Maps a VK_ code to a MIDI note number
function TFormMain.VKeyToMidi(AVK: Word; out AMidi: Byte): Boolean;
begin
  Result := True;
  case AVK of
    Ord('Z'): AMidi := 60;
    Ord('S'): AMidi := 61;
    Ord('X'): AMidi := 62;
    Ord('D'): AMidi := 63;
    Ord('C'): AMidi := 64;
    Ord('V'): AMidi := 65;
    Ord('G'): AMidi := 66;
    Ord('B'): AMidi := 67;
    Ord('H'): AMidi := 68;
    Ord('N'): AMidi := 69;  // A4 = 440 Hz
    Ord('J'): AMidi := 70;
    Ord('M'): AMidi := 71;
    Ord('Q'): AMidi := 72;
    Ord('2'): AMidi := 73;
    Ord('W'): AMidi := 74;
    Ord('3'): AMidi := 75;
    Ord('E'): AMidi := 76;
    Ord('R'): AMidi := 77;
    Ord('5'): AMidi := 78;
    Ord('T'): AMidi := 79;
    Ord('6'): AMidi := 80;
    Ord('Y'): AMidi := 81;
    Ord('7'): AMidi := 82;
    Ord('U'): AMidi := 83;
    Ord('I'): AMidi := 84;
    Ord('9'): AMidi := 85;
    Ord('O'): AMidi := 86;
    Ord('0'): AMidi := 87;
    Ord('P'): AMidi := 88;
  else
    AMidi := 0; Result := False;
  end;
end;

procedure TFormMain.SyncTrackbarCache;
begin
  FAttPos := tbAttack.Position;
  FDecPos := tbDecay.Position;
  FSusPos := tbSustain.Position;
  FRelPos := tbRelease.Position;
end;

{ UI event handlers }

procedure TFormMain.btnOpenMidiClick(Sender: TObject);
begin
  if not dlgOpen.Execute then Exit;
  lblFile.Caption   := ExtractFileName(dlgOpen.FileName);
  lblStatus.Caption := 'Parsing...';
  Application.ProcessMessages;
  if ParseMidiFile(dlgOpen.FileName) then
  begin
    FMidiLoaded := True;
    BuildNoteList;
    RenderToBuffer;
    InvalidateRect(pbWave.Parent.Handle, nil, False);
    lblStatus.Caption := Format('Ready  |  notes: %d  |  %.2f s',
        [FNotes.Count, FPCMLength / SAMPLE_RATE]);
  end
  else
    lblStatus.Caption := 'Parse error';
end;

// Starts MIDI file playback from FSeekSample
procedure TFormMain.btnPlayClick(Sender: TObject);
var WFX: TWaveFormatEx;
begin
  if FPCMLength = 0 then
  begin
    ShowMessage('Load a MIDI file first!'); Exit;
  end;
  StopLive;
  StopPlayback;
  if FSeekSample >= FPCMLength then FSeekSample := 0;

  FillChar(WFX, SizeOf(WFX), 0);
  WFX.wFormatTag      := WAVE_FORMAT_PCM;
  WFX.nChannels       := 1;
  WFX.nSamplesPerSec  := SAMPLE_RATE;
  WFX.wBitsPerSample  := 16;
  WFX.nBlockAlign     := 2;
  WFX.nAvgBytesPerSec := SAMPLE_RATE * 2;

  if waveOutOpen(@FWaveOut, WAVE_MAPPER, @WFX, 0, 0,
                 CALLBACK_NULL) <> MMSYSERR_NOERROR then
  begin
    ShowMessage('Failed to open audio device'); Exit;
  end;

  FillChar(FWaveHeader, SizeOf(FWaveHeader), 0);
  FWaveHeader.lpData         := PAnsiChar(@FPCMBuffer[FSeekSample]);
  FWaveHeader.dwBufferLength := DWORD(FPCMLength - FSeekSample) * 2;
  waveOutPrepareHeader(FWaveOut, @FWaveHeader, SizeOf(FWaveHeader));
  waveOutWrite(FWaveOut, @FWaveHeader, SizeOf(FWaveHeader));

  tmPlayback.Enabled := True;
  lblStatus.Caption  := '▷ Playing...';
end;

procedure TFormMain.btnStopClick(Sender: TObject);
begin
  StopLive;
  StopPlayback;
  lblStatus.Caption := '◻ Stopped';
end;

// Exports the PCM buffer as a standard RIFF WAV file using "file of Byte"
procedure TFormMain.btnExportWAVClick(Sender: TObject);
type
  TWAVHeader = packed record
    ChunkID       : array[0..3] of AnsiChar;
    ChunkSize     : DWORD;
    Format        : array[0..3] of AnsiChar;
    Sub1ID        : array[0..3] of AnsiChar;
    Sub1Size      : DWORD;
    AudioFmt      : Word;
    Channels      : Word;
    SampleRate    : DWORD;
    ByteRate      : DWORD;
    BlockAlign    : Word;
    BitsPerSample : Word;
    Sub2ID        : array[0..3] of AnsiChar;
    Sub2Size      : DWORD;
  end;
var
  F  : file of Byte;
  H  : TWAVHeader;
  PB : PByte;
  i  : Integer;
begin
  if FPCMLength = 0 then
  begin
    ShowMessage('No data to export!'); Exit;
  end;
  dlgSave.Filter     := 'WAV file|*.wav';
  dlgSave.DefaultExt := 'wav';
  if not dlgSave.Execute then Exit;

  FillChar(H, SizeOf(H), 0);
  H.ChunkID       := 'RIFF';
  H.Format        := 'WAVE';
  H.Sub1ID        := 'fmt ';
  H.Sub1Size      := 16;
  H.AudioFmt      := 1;
  H.Channels      := 1;
  H.SampleRate    := SAMPLE_RATE;
  H.BitsPerSample := 16;
  H.BlockAlign    := 2;
  H.ByteRate      := SAMPLE_RATE * 2;
  H.Sub2ID        := 'data';
  H.Sub2Size      := DWORD(FPCMLength) * 2;
  H.ChunkSize     := 36 + H.Sub2Size;

  AssignFile(F, dlgSave.FileName);
  try
    Rewrite(F);
    PB := PByte(@H);
    for i := 0 to SizeOf(H) - 1 do begin Write(F, PB^); Inc(PB); end;
    PB := PByte(@FPCMBuffer[0]);
    for i := 0 to FPCMLength * 2 - 1 do begin Write(F, PB^); Inc(PB); end;
  finally
    CloseFile(F);
  end;
  ShowMessage('WAV saved: ' + dlgSave.FileName);
end;

procedure TFormMain.btnLiveClick(Sender: TObject);
begin
  StopPlayback;
  if FLiveMode then
  begin
    StopLive;
    Exit;
  end;

  FLiveMode  := True;
  FWaveShape := TWaveShape(rgShape.ItemIndex);
  SyncTrackbarCache;

  FLiveSynth := TLiveSynthThread.Create(
    FLiveNotes, PWaveShape(@FWaveShape),
    PIntValue(@FAttPos), PIntValue(@FDecPos),
    PIntValue(@FSusPos), PIntValue(@FRelPos));
  FLiveSynth.Start;

  btnLive.Caption   := 'Stop Live';
  lblStatus.Caption := '◉ LIVE';
  Log('Live mode on. Z S X D C V G B H N J M = C4..B4');
  Log('    Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P = C5..E6');
end;

procedure TFormMain.btnSavePresetClick(Sender: TObject);
var
  F      : file of TADSRPreset;
  Preset : TADSRPreset;
begin
  dlgSave.Filter     := 'ADSR Preset|*.adsr';
  dlgSave.DefaultExt := 'adsr';
  if not dlgSave.Execute then Exit;

  Preset.Attack  := tbAttack.Position;
  Preset.Decay   := tbDecay.Position;
  Preset.Sustain := tbSustain.Position;
  Preset.Release := tbRelease.Position;
  Preset.Shape   := rgShape.ItemIndex;

  AssignFile(F, dlgSave.FileName);
  try
    Rewrite(F);
    Write(F, Preset);
  finally
    CloseFile(F);
  end;
  Log('Preset saved: ' + ExtractFileName(dlgSave.FileName));
end;

procedure TFormMain.btnLoadPresetClick(Sender: TObject);
var
  F      : file of TADSRPreset;
  Preset : TADSRPreset;
begin
  dlgOpen.Filter := 'ADSR Preset|*.adsr';
  if not dlgOpen.Execute then Exit;
  dlgOpen.Filter := 'MIDI files (*.mid;*.midi)|*.mid;*.midi';

  AssignFile(F, dlgOpen.FileName);
  try
    Reset(F);
    if not Eof(F) then
    begin
      Read(F, Preset);
      tbAttack.Position  := Preset.Attack;
      tbDecay.Position   := Preset.Decay;
      tbSustain.Position := Preset.Sustain;
      tbRelease.Position := Preset.Release;
      if (Preset.Shape >= 0) and (Preset.Shape < rgShape.Items.Count) then
        rgShape.ItemIndex := Preset.Shape;
      FWaveShape := TWaveShape(rgShape.ItemIndex);
      SyncTrackbarCache;
      tbChange(nil);
    end;
  finally
    CloseFile(F);
  end;
  Log('Preset loaded: ' + ExtractFileName(dlgOpen.FileName));
end;

// Re-renders with the current ADSR settings and wave shape
procedure TFormMain.btnApplyADSRClick(Sender: TObject);
begin
  if not FMidiLoaded then
  begin
    ShowMessage('Load a MIDI file first!'); Exit;
  end;
  StopPlayback;
  FWaveShape := TWaveShape(rgShape.ItemIndex);
  lblStatus.Caption := 'Rendering...';
  Application.ProcessMessages;
  RenderToBuffer;
  InvalidateRect(pbWave.Parent.Handle, nil, False);
  lblStatus.Caption := Format('Ready  |  %.2f s', [FPCMLength / SAMPLE_RATE]);
end;

procedure TFormMain.btnSaveLogClick(Sender: TObject);
var
  F : TextFile;
  i : Integer;
begin
  dlgSave.Filter     := 'Text file|*.txt';
  dlgSave.DefaultExt := 'txt';
  if not dlgSave.Execute then Exit;

  AssignFile(F, dlgSave.FileName);
  try
    Rewrite(F);
    Writeln(F, 'Phoevra session log  ' + DateTimeToStr(Now));
    Writeln(F, '---');
    for i := 0 to mLog.Lines.Count - 1 do
      Writeln(F, mLog.Lines[i]);
  finally
    CloseFile(F);
  end;
  Log('Log saved: ' + ExtractFileName(dlgSave.FileName));
end;

// Updates label captions and the integer cache used by the synth thread
procedure TFormMain.tbChange(Sender: TObject);
begin
  if not Assigned(lblAVal) then Exit;
  lblAVal.Caption := Format('%.2f s', [tbAttack.Position  / 100.0]);
  lblDVal.Caption := Format('%.2f s', [tbDecay.Position   / 100.0]);
  lblSVal.Caption := Format('%d %%',  [tbSustain.Position]);
  lblRVal.Caption := Format('%.2f s', [tbRelease.Position / 100.0]);
  SyncTrackbarCache;
end;

procedure TFormMain.rgShapeClick(Sender: TObject);
begin
  FWaveShape := TWaveShape(rgShape.ItemIndex);
end;

// Polls waveOut every 50 ms and updates the playhead position
procedure TFormMain.tmPlaybackTimer(Sender: TObject);
var
  MMTime   : TMMTime;
  CurSample: Integer;
begin
  if FWaveOut = 0 then
  begin
    tmPlayback.Enabled := False;
    FPlaybackSample    := 0;
    lblStatus.Caption  := '◻ Ready';
    InvalidateRect(pbWave.Parent.Handle, nil, False);
    Exit;
  end;

  FillChar(MMTime, SizeOf(MMTime), 0);
  MMTime.wType := TIME_BYTES;
  waveOutGetPosition(FWaveOut, @MMTime, SizeOf(MMTime));
  CurSample := FSeekSample + Integer(MMTime.cb div 2);

  if CurSample >= FPCMLength then
  begin
    StopPlayback;
    FPlaybackSample   := 0;
    lblStatus.Caption := '◻ Ready';
  end
  else
    FPlaybackSample := CurSample;

  InvalidateRect(pbWave.Parent.Handle, nil, False);
end;

procedure TFormMain.pbWavePaint(Sender: TObject);
begin
  DrawWave;
end;

// Click on the oscilloscope -- seek to that position
procedure TFormMain.pbWaveMouseDown(Sender: TObject; Button: TMouseButton;
                                    Shift: TShiftState; X, Y: Integer);
begin
  if FPCMLength = 0 then Exit;
  FSeekSample     := Max(0, Min(FPCMLength - 1,
                      Round(X / pbWave.Width * (FPCMLength - 1))));
  FPlaybackSample := FSeekSample;
  if FWaveOut <> 0 then btnPlayClick(nil);
  InvalidateRect(pbWave.Parent.Handle, nil, False);
end;

// Reads keyboard events for virtual keyboard
procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word;
                                 Shift: TShiftState);
var Midi: Byte;
begin
  if not FLiveMode then Exit;
  if ssAlt in Shift then Exit;
  if VKeyToMidi(Key, Midi) then
    FLiveNotes.NoteOn(Midi, NoteToFreq(Midi), 100);
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word;
                               Shift: TShiftState);
var Midi: Byte;
begin
  if not FLiveMode then Exit;
  if VKeyToMidi(Key, Midi) then
    FLiveNotes.NoteOff(Midi);
end;

{ Form lifetime }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  Caption    := 'Phoevra';
  Width      := 660;
  Height     := 740;
  Position   := poScreenCenter;
  KeyPreview := True;

  FEvents         := TMidiEventList.Create;
  FNotes          := TNoteList.Create;
  FLiveNotes      := TLiveNoteList.Create;
  FWaveOut        := 0;
  FPCMLength      := 0;
  FSeekSample     := 0;
  FPlaybackSample := 0;
  FMidiLoaded     := False;
  FLiveMode       := False;
  FWaveShape      := wsSine;
  FWaveBitmap     := TBitmap.Create;

  pbWave.ControlStyle := pbWave.ControlStyle + [csOpaque];

  rgShape.ItemIndex := 0;
  tbChange(nil);
  mLog.Lines.Add('Phoevra ready. Load a MIDI file or press Live to play.');
  mLog.Lines.Add('Click the oscilloscope to seek.');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  StopLive;
  StopPlayback;
  FWaveBitmap.Free;
  FLiveNotes.Free;
  FNotes.Free;
  FEvents.Free;
end;

end.
