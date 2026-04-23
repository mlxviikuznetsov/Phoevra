unit PhoevraMain;
// Phoevra -- MIDI synthesizer.
// Parses a MIDI file, renders notes to a 16-bit PCM buffer
// with sine wave synthesis and ADSR envelope, then plays or exports to WAV.

interface

uses
  Winapi.Windows,
  Winapi.MMSystem,   // waveOut* API for audio playback
  System.SysUtils,
  System.Types,
  System.Math,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  System.Classes;

const
  SAMPLE_RATE   = 44100;
  MAX_AMPLITUDE = 32767;
  FADE_SAMPLES  = SAMPLE_RATE * 5 div 1000;  // 5 ms fade to reduce click/pop

type
  TMidiEventType = (metNoteOn, metNoteOff, metTempo, metOther);

  // A single parsed MIDI event
  TMidiEvent = record
    TimeSeconds : Double;
    EventType   : TMidiEventType;
    Note        : Byte;
    Velocity    : Byte;
    Channel     : Byte;
    Tempo       : LongWord;
  end;

  // Node of the MIDI event singly linked list
  PMidiEventNode = ^TMidiEventNode;
  TMidiEventNode = record
    Data : TMidiEvent;
    Next : PMidiEventNode;
  end;

  // Singly linked list of MIDI events
  TMidiEventList = class
  private
    FHead  : PMidiEventNode;
    FTail  : PMidiEventNode;
    FCount : Integer;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Add(const AEvent: TMidiEvent);
    procedure   Clear;
    property    Head  : PMidiEventNode read FHead;
    property    Count : Integer        read FCount;
  end;

  // A resolved note with start/end time and frequency
  TActiveNote = record
    Note      : Byte;
    Frequency : Double;
    StartSec  : Double;
    EndSec    : Double;
    Velocity  : Byte;
  end;

  // Node of the active note singly linked list
  PNoteNode = ^TNoteNode;
  TNoteNode = record
    Data : TActiveNote;
    Next : PNoteNode;
  end;

  // Singly linked list of active notes
  TNoteList = class
  private
    FHead  : PNoteNode;
    FCount : Integer;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Add(const ANote: TActiveNote);
    procedure   Clear;
    property    Head  : PNoteNode read FHead;
    property    Count : Integer   read FCount;
  end;

  TFormMain = class(TForm)
    // UI controls
    pnlTop       : TPanel;
    btnOpenMidi  : TButton;
    btnPlay      : TButton;
    btnStop      : TButton;
    btnExportWAV : TButton;
    lblFile      : TLabel;
    lblStatus    : TLabel;

    pnlADSR      : TPanel;
    lblADSRTitle : TLabel;
    lblA : TLabel;  tbAttack  : TTrackBar;  lblAVal : TLabel;
    lblD : TLabel;  tbDecay   : TTrackBar;  lblDVal : TLabel;
    lblS : TLabel;  tbSustain : TTrackBar;  lblSVal : TLabel;
    lblR : TLabel;  tbRelease : TTrackBar;  lblRVal : TLabel;
    btnApplyADSR : TButton;

    pbWave       : TPaintBox;
    tmPlayback   : TTimer;
    mLog         : TMemo;
    dlgOpen      : TOpenDialog;
    dlgSave      : TSaveDialog;

    // UI event handlers
    procedure btnOpenMidiClick(Sender: TObject);
    procedure btnPlayClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnExportWAVClick(Sender: TObject);
    procedure btnApplyADSRClick(Sender: TObject);
    procedure tbChange(Sender: TObject);
    procedure tmPlaybackTimer(Sender: TObject);
    procedure pbWavePaint(Sender: TObject);
    procedure pbWaveMouseDown(Sender: TObject; Button: TMouseButton;
                              Shift: TShiftState; X, Y: Integer);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);

  private
    FEvents         : TMidiEventList;
    FNotes          : TNoteList;
    FPCMBuffer      : array of SmallInt;
    FPCMLength      : Integer;
    FWaveOut        : HWAVEOUT;
    FWaveHeader     : TWAVEHDR;
    FSeekSample     : Integer;   // playback start position (seek)
    FPlaybackSample : Integer;   // current position for playhead drawing
    FMidiLoaded     : Boolean;   // true after successful parse
    FWaveBitmap     : TBitmap;   // off-screen buffer to prevent flicker

    // Core algorithms
    function  ReadVarLen(const ABuf: array of Byte;
                         var APos: Integer): LongWord;
    function  ParseMidiFile(const AFileName: string): Boolean;
    function  NoteToFreq(ANote: Byte): Double;
    function  GenerateSine(ASampleIdx: Integer; AFreq, AAmp: Double): Double;
    function  ApplyADSR(ASampleIdx, ATotalSamples: Integer): Double;
    procedure RenderToBuffer;

    // Helpers
    procedure BuildNoteList;
    procedure StopPlayback;
    procedure DrawWave;
    procedure RenderWaveToBitmap;
    procedure Log(const S: string);
    function  ReadUInt32BE(const B: array of Byte; P: Integer): LongWord;
    function  ReadUInt16BE(const B: array of Byte; P: Integer): Word;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

{ TMidiEventList }

constructor TMidiEventList.Create;
begin
  inherited;
  FHead := nil; FTail := nil; FCount := 0;
end;

destructor TMidiEventList.Destroy;
begin
  Clear; inherited;
end;

// Appends a new event node to the tail of the list
procedure TMidiEventList.Add(const AEvent: TMidiEvent);
var Node: PMidiEventNode;
begin
  New(Node);
  Node^.Data := AEvent;
  Node^.Next := nil;
  if FTail <> nil then FTail^.Next := Node
  else                  FHead      := Node;
  FTail := Node;
  Inc(FCount);
end;

// Frees all nodes and resets the list
procedure TMidiEventList.Clear;
var Node, Nxt: PMidiEventNode;
begin
  Node := FHead;
  while Node <> nil do
  begin
    Nxt := Node^.Next;
    Dispose(Node);
    Node := Nxt;
  end;
  FHead := nil; FTail := nil; FCount := 0;
end;

{ TNoteList }

constructor TNoteList.Create;
begin
  inherited;
  FHead := nil; FCount := 0;
end;

destructor TNoteList.Destroy;
begin
  Clear; inherited;
end;

// Prepends a new note node to the head of the list
procedure TNoteList.Add(const ANote: TActiveNote);
var Node: PNoteNode;
begin
  New(Node);
  Node^.Data := ANote;
  Node^.Next := FHead;
  FHead      := Node;
  Inc(FCount);
end;

// Frees all nodes and resets the list
procedure TNoteList.Clear;
var Node, Nxt: PNoteNode;
begin
  Node := FHead;
  while Node <> nil do
  begin
    Nxt := Node^.Next;
    Dispose(Node);
    Node := Nxt;
  end;
  FHead := nil; FCount := 0;
end;

{ Big-endian read helpers }

function TFormMain.ReadUInt32BE(const B: array of Byte; P: Integer): LongWord;
begin
  Result := (LongWord(B[P])   shl 24) or (LongWord(B[P+1]) shl 16)
          or (LongWord(B[P+2]) shl  8) or  LongWord(B[P+3]);
end;

function TFormMain.ReadUInt16BE(const B: array of Byte; P: Integer): Word;
begin
  Result := (Word(B[P]) shl 8) or Word(B[P+1]);
end;

{ Variable-length quantity decoding.
  Each byte contributes 7 bits; bit 7 set means more bytes follow.
  Example: $81 $00 -> (1 shl 7) or 0 = 128 ticks. }
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

{ MIDI file parser.
  Reads the file into a byte array via "file of Byte", then walks
  MThd and MTrk chunks manually. Absolute time in seconds is computed as:
    t += delta * (tempo / ticksPerBeat) / 1_000_000 }
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

  // Read the entire file into a dynamic byte array
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

  // Verify MThd signature
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

  Tempo      := 500000; // default 120 BPM
  LastStatus := 0;

  // Walk all chunks, process only MTrk ones
  while Pos + 8 <= Length(Buf) do
  begin
    Tag[0] := Char(Buf[Pos]);   Tag[1] := Char(Buf[Pos+1]);
    Tag[2] := Char(Buf[Pos+2]); Tag[3] := Char(Buf[Pos+3]);
    Inc(Pos, 4);
    ChunkLen := ReadUInt32BE(Buf, Pos); Inc(Pos, 4);
    TrackEnd := Pos + Integer(ChunkLen);

    if (Tag[0]<>'M') or (Tag[1]<>'T') or (Tag[2]<>'r') or (Tag[3]<>'k') then
    begin
      Pos := TrackEnd;
      Continue;
    end;

    AbsSec := 0;

    while Pos < TrackEnd do
    begin
      Delta  := ReadVarLen(Buf, Pos);
      AbsSec := AbsSec + Delta * (Tempo / TicksPerBeat) / 1000000.0;

      if Pos >= TrackEnd then Break;

      // Running status: if high bit is clear, reuse last status byte
      if (Buf[Pos] and $80) <> 0 then
      begin
        Status     := Buf[Pos];
        LastStatus := Status;
        Inc(Pos);
      end
      else
        Status := LastStatus;

      EvType  := Status and $F0;
      Channel := Status and $0F;

      // Note Off ($80)
      if EvType = $80 then
      begin
        if Pos + 1 >= TrackEnd then Break;
        P1 := Buf[Pos]; Inc(Pos);
        P2 := Buf[Pos]; Inc(Pos);
        FillChar(Ev, SizeOf(Ev), 0);
        Ev.TimeSeconds := AbsSec;
        Ev.EventType   := metNoteOff;
        Ev.Note        := P1;
        Ev.Velocity    := P2;
        Ev.Channel     := Channel;
        FEvents.Add(Ev);
      end

      // Note On ($90); velocity=0 is treated as Note Off
      else if EvType = $90 then
      begin
        if Pos + 1 >= TrackEnd then Break;
        P1 := Buf[Pos]; Inc(Pos);
        P2 := Buf[Pos]; Inc(Pos);
        FillChar(Ev, SizeOf(Ev), 0);
        Ev.TimeSeconds := AbsSec;
        Ev.Channel     := Channel;
        Ev.Note        := P1;
        Ev.Velocity    := P2;
        if P2 = 0 then Ev.EventType := metNoteOff
        else            Ev.EventType := metNoteOn;
        FEvents.Add(Ev);
      end

      // Meta event ($FF): handle tempo change ($51), skip others
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
          Ev.TimeSeconds := AbsSec;
          Ev.EventType   := metTempo;
          Ev.Tempo       := Tempo;
          FEvents.Add(Ev);
          Log(Format('Tempo changed: %.1f BPM', [60000000.0 / Tempo]));
        end;
        Inc(Pos, Integer(ChunkLen));
      end

      // Two-byte events: AfterTouch, Control Change, Pitch Bend
      else if EvType in [$A0, $B0, $E0] then Inc(Pos, 2)
      // One-byte events: Program Change, Channel Pressure
      else if EvType in [$C0, $D0] then Inc(Pos, 1)
      else Inc(Pos);
    end;

    Pos := TrackEnd;
  end;

  Log(Format('Events parsed: %d', [FEvents.Count]));
  Result := FEvents.Count > 0;
end;

{ Convert MIDI note number to frequency (equal temperament).
  f(n) = 440 * 2^((n - 69) / 12),  where n=69 is A4 = 440 Hz. }
function TFormMain.NoteToFreq(ANote: Byte): Double;
begin
  Result := 440.0 * Power(2.0, (Integer(ANote) - 69) / 12.0);
end;

{ Sine wave sample.
  y(i) = A * sin(2pi * f * i / SampleRate) }
function TFormMain.GenerateSine(ASampleIdx: Integer;
                                 AFreq, AAmp: Double): Double;
begin
  Result := AAmp * Sin(2.0 * Pi * AFreq * (ASampleIdx / SAMPLE_RATE));
end;

{ ADSR envelope, returns a gain coefficient in [0..1].
  Attack  [0 .. A)          : ramp up   0 -> 1
  Decay   [A .. A+D)        : ramp down 1 -> S
  Sustain [A+D .. Total-R)  : hold      S
  Release [Total-R .. Total): ramp down S -> 0 }
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
  RStart := ATotalSamples - R;

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

// Matches each NoteOff with its earliest unused NoteOn on the same note
// and channel, producing a list of TActiveNote records.
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
          OnNode^.Data.TimeSeconds := 1e18; // mark NoteOn as consumed
          Break;
        end;
        OnNode := OnNode^.Next;
      end;
    end;
    Node := Node^.Next;
  end;
  Log(Format('Notes to render: %d', [FNotes.Count]));
end;

{ Render all notes into a 16-bit PCM buffer.
  Each note gets a short linear fade-in/out (FADE_SAMPLES) to eliminate
  click/pop at note boundaries. Buffer length is determined dynamically. }
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
  i         : Integer;
begin
  if FNotes.Count = 0 then
  begin
    Log('No notes to render'); Exit;
  end;

  // Determine total buffer length from the last note end time
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

  // Mix all notes into the Double buffer
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
          + GenerateSine(i, Node^.Data.Frequency, 1.0)
          * ApplyADSR(i, NoteSmp)
          * VelScale
          * FadeCoeff;
      end;
    end;
    Node := Node^.Next;
  end;

  // Find peak for normalization
  MaxVal := 0;
  for i := 0 to TotalSmp - 1 do
    if Abs(MixBuf[i]) > MaxVal then MaxVal := Abs(MixBuf[i]);

  // Convert Double -> SmallInt (16-bit PCM)
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
    pbWave.Invalidate;
    lblStatus.Caption := Format('Ready  |  notes: %d  |  %.2f s',
        [FNotes.Count, FPCMLength / SAMPLE_RATE]);
  end
  else
    lblStatus.Caption := 'Parse error';
end;

// Starts playback from FSeekSample
procedure TFormMain.btnPlayClick(Sender: TObject);
var WFX: TWaveFormatEx;
begin
  if FPCMLength = 0 then
  begin
    ShowMessage('Load a MIDI file first!'); Exit;
  end;
  StopPlayback;
  if FSeekSample >= FPCMLength then FSeekSample := 0;

  // Configure mono 16-bit PCM format
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
  lblStatus.Caption  := '▶ Playing...';
end;

procedure TFormMain.btnStopClick(Sender: TObject);
begin
  StopPlayback;
  lblStatus.Caption := '■ Stopped';
end;

// Re-renders with current ADSR settings without reloading the MIDI file
procedure TFormMain.btnApplyADSRClick(Sender: TObject);
begin
  if not FMidiLoaded then
  begin
    ShowMessage('Load a MIDI file first!'); Exit;
  end;
  StopPlayback;
  lblStatus.Caption := 'Rendering...';
  Application.ProcessMessages;
  RenderToBuffer;
  pbWave.Invalidate;
  lblStatus.Caption := Format('Ready  |  %.2f s', [FPCMLength / SAMPLE_RATE]);
end;

// Updates ADSR label captions -- does not trigger re-render
procedure TFormMain.tbChange(Sender: TObject);
begin
  if not Assigned(lblAVal) then Exit;
  lblAVal.Caption := Format('%.2f s', [tbAttack.Position  / 100.0]);
  lblDVal.Caption := Format('%.2f s', [tbDecay.Position   / 100.0]);
  lblSVal.Caption := Format('%d %%',  [tbSustain.Position]);
  lblRVal.Caption := Format('%.2f s', [tbRelease.Position / 100.0]);
end;

// Click on the oscilloscope -- seek to that position
procedure TFormMain.pbWaveMouseDown(Sender: TObject; Button: TMouseButton;
                                    Shift: TShiftState; X, Y: Integer);
begin
  if FPCMLength = 0 then Exit;
  FSeekSample     := Max(0, Min(FPCMLength - 1,
                      Round(X / pbWave.Width * (FPCMLength - 1))));
  FPlaybackSample := FSeekSample;
  if FWaveOut <> 0 then btnPlayClick(nil);  // restart from new position if playing
  pbWave.Invalidate;
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
    lblStatus.Caption  := '■ Ready';
    pbWave.Invalidate;
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
    lblStatus.Caption := '■ Ready';
  end
  else
    FPlaybackSample := CurSample;

  pbWave.Invalidate;
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
  if not dlgSave.Execute then Exit;

  // Fill RIFF/WAV header
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
    // Write 44-byte header
    PB := PByte(@H);
    for i := 0 to SizeOf(H) - 1 do begin Write(F, PB^); Inc(PB); end;
    // Write PCM samples
    PB := PByte(@FPCMBuffer[0]);
    for i := 0 to FPCMLength * 2 - 1 do begin Write(F, PB^); Inc(PB); end;
  finally
    CloseFile(F);
  end;
  ShowMessage('WAV saved: ' + dlgSave.FileName);
end;

// Renders the static waveform shape onto FWaveBitmap once after render.
// Called only when PCM data changes, not every frame.
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

    // Horizontal axis
    Pen.Color := $444444;
    Pen.Width := 1;
    MoveTo(0, PH div 2);
    LineTo(PW, PH div 2);

    if FPCMLength = 0 then Exit;

    // Wave
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

// Draws the oscilloscope. The static wave comes from FWaveBitmap (pre-rendered).
// Only the playhead line is re-drawn each frame.
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

  // Copy static background in one BitBlt -- no flicker
  BitBlt(C.Handle, 0, 0, PW, PH, FWaveBitmap.Canvas.Handle, 0, 0, SRCCOPY);

  if FPCMLength = 0 then Exit;

  PlayX := Round(FPlaybackSample / FPCMLength * PW);
  PlayX := Max(0, Min(PW - 1, PlayX));

  // White vertical playhead line
  C.Pen.Color := $FFFFFF;
  C.Pen.Width := 1;
  C.MoveTo(PlayX, 0);
  C.LineTo(PlayX, PH);
end;

procedure TFormMain.pbWavePaint(Sender: TObject);
begin
  DrawWave;
end;

procedure TFormMain.Log(const S: string);
begin
  mLog.Lines.Add(S);
end;

{ Form lifetime }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  Caption  := 'Phoevra';
  Width    := 660;
  Height   := 680;
  Position := poScreenCenter;

  FEvents         := TMidiEventList.Create;
  FNotes          := TNoteList.Create;
  FWaveOut        := 0;
  FPCMLength      := 0;
  FSeekSample     := 0;
  FPlaybackSample := 0;
  FMidiLoaded     := False;
  FWaveBitmap     := TBitmap.Create;

  tbChange(nil);
  mLog.Lines.Add('Phoevra ready. Load a MIDI file.');
  mLog.Lines.Add('Click the oscilloscope to seek.');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  StopPlayback;
  FWaveBitmap.Free;
  FNotes.Free;
  FEvents.Free;
end;

end.
