unit PhoevraTypes;

interface

uses
  Winapi.Windows,
  Winapi.MMSystem,
  System.SysUtils,
  System.Math,
  System.Classes;

const
  SAMPLE_RATE   = 44100;
  MAX_AMPLITUDE = 32767;
  FADE_SAMPLES  = SAMPLE_RATE * 5 div 1000;
  LIVE_CHUNK = 4096;

type
  TWaveShape = (wsSine, wsSquare, wsSawtooth, wsTriangle);

  // ADSR preset saved to file
  TADSRPreset = packed record
    Attack  : Integer;
    Decay   : Integer;
    Sustain : Integer;
    Release : Integer;
    Shape   : Integer;
  end;

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

  // One currently-held key in live mode
  PLiveNote = ^TLiveNote;
  TLiveNote = record
    MidiNote  : Byte;
    Freq      : Double;
    Velocity  : Byte;
    Phase     : Double;
    Age       : Integer;
    Releasing : Boolean;
    RelAge    : Integer;
    Next      : PLiveNote;
  end;

  // Singly linked list of live notes
  TLiveNoteList = class
  private
    FHead  : PLiveNote;
    FCount : Integer;
    FLock  : TRTLCriticalSection;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure NoteOn(AMidi: Byte; AFreq: Double; AVel: Byte);
    procedure NoteOff(AMidi: Byte);
    procedure MixChunk(ABuf: PSmallInt; ACount: Integer;
                       AShape: TWaveShape;
                       AAttackSmp, ARelSmp: Integer;
                       ASustain: Double);
    procedure Clear;
    property  Count : Integer read FCount;
  end;

  // Named pointer types (for field/parameter declarations)
  PWaveShape = ^TWaveShape;
  PIntValue  = ^Integer;

  // Audio thread for live synthesis
  TLiveSynthThread = class(TThread)
  private
    FWaveOut    : HWAVEOUT;
    FHeaders    : array[0..1] of TWAVEHDR;
    FBufs       : array[0..1] of array[0..LIVE_CHUNK - 1] of SmallInt;
    FNotes      : TLiveNoteList;
    FShapePtr   : PWaveShape;
    FAttackPtr  : PIntValue;
    FDecayPtr   : PIntValue;
    FSustainPtr : PIntValue;
    FReleasePtr : PIntValue;
  public
    constructor Create(ANotes: TLiveNoteList;
                       AShape: PWaveShape;
                       AAttack, ADecay, ASustain, ARelease: PIntValue);
    destructor  Destroy; override;
    procedure   Execute; override;
  end;

implementation

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

{ TLiveNoteList }

constructor TLiveNoteList.Create;
begin
  inherited;
  FHead  := nil;
  FCount := 0;
  InitializeCriticalSection(FLock);
end;

destructor TLiveNoteList.Destroy;
begin
  Clear;
  DeleteCriticalSection(FLock);
  inherited;
end;

procedure TLiveNoteList.NoteOn(AMidi: Byte; AFreq: Double; AVel: Byte);
var Node, Cur: PLiveNote;
begin
  EnterCriticalSection(FLock);
  try
    // Ignore key-repeat: note already held
    Cur := FHead;
    while Cur <> nil do
    begin
      if (Cur^.MidiNote = AMidi) and not Cur^.Releasing then Exit;
      Cur := Cur^.Next;
    end;
    New(Node);
    Node^.MidiNote  := AMidi;
    Node^.Freq      := AFreq;
    Node^.Velocity  := AVel;
    Node^.Phase     := 0.0;
    Node^.Age       := 0;
    Node^.Releasing := False;
    Node^.RelAge    := 0;
    Node^.Next      := FHead;
    FHead           := Node;
    Inc(FCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLiveNoteList.NoteOff(AMidi: Byte);
var Cur: PLiveNote;
begin
  EnterCriticalSection(FLock);
  try
    Cur := FHead;
    while Cur <> nil do
    begin
      if (Cur^.MidiNote = AMidi) and not Cur^.Releasing then
      begin
        Cur^.Releasing := True;
        Cur^.RelAge    := 0;
        Break;
      end;
      Cur := Cur^.Next;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

// Synthesises one chunk into ABuf (called from the audio thread)
procedure TLiveNoteList.MixChunk(ABuf: PSmallInt; ACount: Integer;
                                  AShape: TWaveShape;
                                  AAttackSmp, ARelSmp: Integer;
                                  ASustain: Double);
var
  i          : Integer;
  Mix        : array[0..LIVE_CHUNK - 1] of Double;
  Cur, Prv   : PLiveNote;
  Nxt        : PLiveNote;
  Env, Gain  : Double;
  VelScale   : Double;
  Sample     : Double;
  PhStep     : Double;
  T          : Double;
  Done       : Boolean;
begin
  for i := 0 to ACount - 1 do Mix[i] := 0.0;

  EnterCriticalSection(FLock);
  try
    Prv := nil;
    Cur := FHead;
    while Cur <> nil do
    begin
      VelScale := Cur^.Velocity / 127.0;
      PhStep   := 2.0 * Pi * Cur^.Freq / SAMPLE_RATE;
      Done     := False;

      for i := 0 to ACount - 1 do
      begin
        // Attack ramp
        if (AAttackSmp > 0) and (Cur^.Age < AAttackSmp) then
          Env := Cur^.Age / AAttackSmp
        else
          Env := 1.0;

        // Sustain / release gain
        if Cur^.Releasing then
        begin
          if ARelSmp > 0 then
            Gain := ASustain * (1.0 - Cur^.RelAge / ARelSmp)
          else
            Gain := 0.0;
          if Gain < 0.0 then Gain := 0.0;
          Inc(Cur^.RelAge);
          if Cur^.RelAge >= ARelSmp then
          begin
            Done := True;
            Break;
          end;
        end
        else
          Gain := ASustain;

        // Waveform sample at current phase
        case AShape of
          wsSquare:
            if Sin(Cur^.Phase) >= 0.0 then Sample :=  1.0
            else                           Sample := -1.0;
          wsSawtooth:
            Sample := 1.0 - Cur^.Phase / Pi;
          wsTriangle:
            begin
              T := Cur^.Phase / Pi;
              if T > 1.0 then T := 2.0 - T;
              Sample := T * 2.0 - 1.0;
            end;
        else
          Sample := Sin(Cur^.Phase);
        end;

        Mix[i] := Mix[i] + Sample * Env * Gain * VelScale;

        // Advance phase accumulator, keep in [0..2Pi]
        Cur^.Phase := Cur^.Phase + PhStep;
        if Cur^.Phase >= 2.0 * Pi then
          Cur^.Phase := Cur^.Phase - 2.0 * Pi;

        if not Cur^.Releasing then Inc(Cur^.Age);
      end;

      Nxt := Cur^.Next;
      if Done then
      begin
        // Unlink this node; Prv stays unchanged so next iteration is correct
        if Prv = nil then FHead     := Nxt
        else              Prv^.Next := Nxt;
        Dispose(Cur);
        Dec(FCount);
        Cur := Nxt;
      end
      else
      begin
        Prv := Cur;
        Cur := Nxt;
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;

  // Soft clip and convert to 16-bit PCM
  for i := 0 to ACount - 1 do
  begin
    if Mix[i] >  1.0 then Mix[i] :=  1.0;
    if Mix[i] < -1.0 then Mix[i] := -1.0;
    ABuf^ := Round(Mix[i] * MAX_AMPLITUDE);
    Inc(ABuf);
  end;
end;

procedure TLiveNoteList.Clear;
var Node, Nxt: PLiveNote;
begin
  EnterCriticalSection(FLock);
  try
    Node := FHead;
    while Node <> nil do
    begin
      Nxt := Node^.Next;
      Dispose(Node);
      Node := Nxt;
    end;
    FHead  := nil;
    FCount := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ TLiveSynthThread }

constructor TLiveSynthThread.Create(ANotes: TLiveNoteList; AShape: PWaveShape;
                                    AAttack, ADecay,
                                    ASustain, ARelease: PIntValue);
begin
  inherited Create(True);
  FNotes      := ANotes;
  FShapePtr   := AShape;
  FAttackPtr  := AAttack;
  FDecayPtr   := ADecay;
  FSustainPtr := ASustain;
  FReleasePtr := ARelease;
  FreeOnTerminate := False;
  Priority := tpTimeCritical;
end;

destructor TLiveSynthThread.Destroy;
var i: Integer;
begin
  if FWaveOut <> 0 then
  begin
    waveOutReset(FWaveOut);
    for i := 0 to 1 do
      if (FHeaders[i].dwFlags and WHDR_PREPARED) <> 0 then
        waveOutUnprepareHeader(FWaveOut, @FHeaders[i], SizeOf(TWAVEHDR));
    waveOutClose(FWaveOut);
    FWaveOut := 0;
  end;
  inherited;
end;

procedure TLiveSynthThread.Execute;
var
  WFX    : TWaveFormatEx;
  Cur    : Integer;
  AttSmp : Integer;
  RelSmp : Integer;
  Sus    : Double;
begin
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
    FWaveOut := 0; Exit;
  end;

  // Prepare both headers once; data pointers never change
  FillChar(FHeaders, SizeOf(FHeaders), 0);
  for Cur := 0 to 1 do
  begin
    FHeaders[Cur].lpData         := PAnsiChar(@FBufs[Cur][0]);
    FHeaders[Cur].dwBufferLength := LIVE_CHUNK * SizeOf(SmallInt);
    waveOutPrepareHeader(FWaveOut, @FHeaders[Cur], SizeOf(TWAVEHDR));
  end;

  Cur := 0;
  while not Terminated do
  begin
    // Wait until the driver has finished with this buffer
    while (FHeaders[Cur].dwFlags and WHDR_INQUEUE) <> 0 do
    begin
      if Terminated then Break;
      Sleep(1);
    end;
    if Terminated then Break;

    // Read ADSR values written by the UI thread
    AttSmp := Round(FAttackPtr^  / 100.0 * SAMPLE_RATE);
    RelSmp := Round(FReleasePtr^ / 100.0 * SAMPLE_RATE);
    Sus    := FSustainPtr^ / 100.0;

    FNotes.MixChunk(@FBufs[Cur][0], LIVE_CHUNK,
                    FShapePtr^, AttSmp, RelSmp, Sus);

    waveOutWrite(FWaveOut, @FHeaders[Cur], SizeOf(TWAVEHDR));
    Cur := 1 - Cur;
  end;

  waveOutReset(FWaveOut);
  for Cur := 0 to 1 do
    waveOutUnprepareHeader(FWaveOut, @FHeaders[Cur], SizeOf(TWAVEHDR));
  waveOutClose(FWaveOut);
  FWaveOut := 0;
end;

end.
