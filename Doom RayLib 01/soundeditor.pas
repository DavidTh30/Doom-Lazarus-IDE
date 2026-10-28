unit soundeditor;

{ RayDoom sound editor: tweak the synthesis parameters of every game sound effect,
  hear the result instantly, and save them to sounds.cfg (which the game loads). }

{$mode objfpc}{$H+}

interface

procedure RunSoundEditor;

implementation

uses
  SysUtils, Classes, Math, Process, raylib, doomparams, doomsound, edui;

const
  WIN_W = 1280;
  WIN_H = 800;
  LIST_X = 16;
  WAVE_X = 252;
  WAVE_Y = 64;
  WAVE_W = 1012;
  WAVE_H = 190;
  SLIDER_Y = 282;
  SLIDER_W = 490;
  MAX_UNDO = 200;

type
  TUndoEntry = record
    Id: Integer;
    P: TSfxParams;
  end;

var
  Cur: Integer = 0;
  Samples: TSamples;
  Dirty, Quit, QuitPending, AutoPlay, AutoTest, AudioOK, HasClip: Boolean;
  UndoBuf: array[0..MAX_UNDO - 1] of TUndoEntry;
  UndoCount: Integer;
  Clip: TSfxParams;
  PlayStart: Double;
  MsgText: string;
  MsgTimer: Single;
  MsgCol: TColor;

procedure Say(const s: string; good: Boolean = True);
begin
  MsgText := s;
  MsgTimer := 4;
  if good then MsgCol := C(120, 230, 120) else MsgCol := C(255, 110, 90);
end;

function ConfigPath: string;
begin
  Result := ExePath(SFX_CONFIG_FILE);
end;

function IsDefault(id: Integer): Boolean;
begin
  Result := CompareMem(@SfxParams[id], @DefaultSfx[id], SizeOf(TSfxParams));
end;

procedure Resynth;
begin
  Samples := Synthesize(SfxParams[Cur]);
end;

procedure PlayCurrent;
begin
  if not AudioOK then
  begin
    Say('No audio device - sounds cannot be played', False);
    Exit;
  end;
  PlaySfx(Sfx[Cur]);
  PlayStart := GetTime;
end;

procedure StopCurrent;
begin
  if AudioOK then StopSound(Sfx[Cur]);
end;

procedure SelectSound(id: Integer);
begin
  if id = Cur then Exit;
  StopCurrent;
  Cur := (id + NUM_SFX) mod NUM_SFX;
  Resynth;
end;

// Called after any finished change of the current sound
procedure Changed(play: Boolean);
begin
  Dirty := True;
  Resynth;
  ReloadSound(Cur);
  if play and AutoPlay then PlayCurrent;
end;

procedure PushUndo(id: Integer; const p: TSfxParams);
begin
  if UndoCount = MAX_UNDO then
  begin
    Move(UndoBuf[1], UndoBuf[0], SizeOf(TUndoEntry) * (MAX_UNDO - 1));
    Dec(UndoCount);
  end;
  UndoBuf[UndoCount].Id := id;
  UndoBuf[UndoCount].P := p;
  Inc(UndoCount);
end;

procedure DoUndo;
begin
  if UndoCount = 0 then
  begin
    Say('Nothing to undo', False);
    Exit;
  end;
  Dec(UndoCount);
  SelectSound(UndoBuf[UndoCount].Id);
  SfxParams[Cur] := UndoBuf[UndoCount].P;
  Changed(False);
  Say('Undo: ' + SfxNames[Cur]);
end;

procedure ResetCurrent;
begin
  PushUndo(Cur, SfxParams[Cur]);
  SfxParams[Cur] := DefaultSfx[Cur];
  Changed(True);
  Say(SfxNames[Cur] + ' reset to default');
end;

procedure ResetAll;
var
  i: Integer;
begin
  for i := 0 to NUM_SFX - 1 do
    if not IsDefault(i) then
    begin
      PushUndo(i, SfxParams[i]);
      SfxParams[i] := DefaultSfx[i];
      ReloadSound(i);
    end;
  Dirty := True;
  Resynth;
  Say('All sounds reset to defaults (not saved yet)');
end;

// Small random variation of the continuous parameters - handy for finding new sounds
procedure Mutate;
var
  i: Integer;
  r: Single;
begin
  PushUndo(Cur, SfxParams[Cur]);
  for i := 0 to NUM_SP - 1 do
    if not SpInfo[i].IsInt and (i <> SP_DUR) and (i <> SP_VOLUME) then
    begin
      r := (SpInfo[i].Max - SpInfo[i].Min) * 0.08;
      SfxParams[Cur][i] := ClampParam(SpInfo[i], SfxParams[Cur][i] + (Random - 0.5) * 2 * r);
    end;
  Changed(True);
  Say('Mutated ' + SfxNames[Cur] + ' (Ctrl+Z to undo)');
end;

procedure CopyParams;
begin
  Clip := SfxParams[Cur];
  HasClip := True;
  Say('Copied ' + SfxNames[Cur]);
end;

procedure PasteParams;
begin
  if not HasClip then
  begin
    Say('Nothing copied yet', False);
    Exit;
  end;
  PushUndo(Cur, SfxParams[Cur]);
  SfxParams[Cur] := Clip;
  Changed(True);
  Say('Pasted into ' + SfxNames[Cur]);
end;

function SaveConfig: Boolean;
begin
  Result := SaveSfxConfig(ConfigPath);
  if Result then
  begin
    Dirty := False;
    Say('Saved ' + ConfigPath);
  end
  else
    Say('Could not save ' + ConfigPath, False);
end;

procedure ReloadConfig;
var
  i: Integer;
begin
  ResetAllSfx;
  if LoadSfxConfig(ConfigPath) then
    Say('Reloaded ' + ConfigPath)
  else
    Say('No ' + SFX_CONFIG_FILE + ' yet - using built-in sounds');
  for i := 0 to NUM_SFX - 1 do ReloadSound(i);
  UndoCount := 0;
  Dirty := False;
  Resynth;
end;

procedure ExportWav;
var
  data: TByteArray;
  fs: TFileStream;
  fn: string;
begin
  fn := ExePath(SfxKeys[Cur] + '.wav');
  data := WavBytes(Samples);
  try
    fs := TFileStream.Create(fn, fmCreate);
    try
      fs.WriteBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    Say('Exported ' + fn);
  except
    on E: Exception do Say('Export failed: ' + E.Message, False);
  end;
end;

procedure TestInGame;
var
  exe: string;
  p: TProcess;
begin
  if not SaveConfig then Exit;
  exe := ExtractFilePath(ParamStr(0)) + 'RayDoom.exe';
  if not FileExists(exe) then
  begin
    Say('RayDoom.exe not found - build RayDoom.lpi first', False);
    Exit;
  end;
  p := TProcess.Create(nil);
  try
    p.Executable := exe;
    p.CurrentDirectory := ExtractFilePath(exe);
    p.Execute;
    Say('Launched RayDoom with your sounds');
  except
    on E: Exception do Say('Could not start RayDoom: ' + E.Message, False);
  end;
  p.Free;
end;

{ ================================================================ drawing }

procedure DrawSoundList;
var
  i: Integer;
  lbl: string;
begin
  SectionTitle('SOUNDS', LIST_X, WAVE_Y);
  for i := 0 to NUM_SFX - 1 do
  begin
    lbl := SfxNames[i];
    if not IsDefault(i) then lbl := lbl + ' *';
    if Button(LIST_X, WAVE_Y + 28 + i * 42, 220, 36, lbl, i = Cur) then SelectSound(i);
  end;
  DrawText('* = changed from default', LIST_X, WAVE_Y + 28 + NUM_SFX * 42 + 4, 14, C(150, 150, 150));
end;

procedure DrawWaveform;
var
  x, i0, i1, i, n, ymin, ymax, mid: Integer;
  lo, hi, dur, t: Single;
  col: TColor;
begin
  DrawRectangle(WAVE_X, WAVE_Y, WAVE_W, WAVE_H, C(18, 20, 22));
  mid := WAVE_Y + WAVE_H div 2;
  n := Length(Samples);
  dur := SfxParams[Cur][SP_DUR];
  // time grid every 0.1 s
  t := 0;
  while t < dur do
  begin
    x := WAVE_X + Round(t / dur * WAVE_W);
    DrawRectangle(x, WAVE_Y, 1, WAVE_H, C(40, 44, 48));
    DrawText(PChar(FormatFloat('0.0', t, CfgFormat)), x + 3, WAVE_Y + WAVE_H - 14, 10, C(110, 110, 110));
    t := t + 0.1;
  end;
  DrawRectangle(WAVE_X, mid, WAVE_W, 1, C(60, 64, 70));
  if n > 0 then
    for x := 0 to WAVE_W - 1 do
    begin
      i0 := Int64(x) * n div WAVE_W;
      i1 := Max(i0 + 1, Int64(x + 1) * n div WAVE_W);
      lo := 1;
      hi := -1;
      for i := i0 to Min(i1, n) - 1 do
      begin
        if Samples[i] < lo then lo := Samples[i];
        if Samples[i] > hi then hi := Samples[i];
      end;
      ymin := mid - Round(hi * (WAVE_H div 2 - 4));
      ymax := mid - Round(lo * (WAVE_H div 2 - 4));
      if (hi >= 0.99) or (lo <= -0.99) then col := C(255, 80, 60) else col := C(90, 220, 140);
      DrawRectangle(WAVE_X + x, ymin, 1, Max(1, ymax - ymin + 1), col);
    end;
  // playhead
  if AudioOK and IsSoundPlaying(Sfx[Cur]) then
  begin
    x := WAVE_X + Round(EnsureRange((GetTime - PlayStart) / dur, 0, 1) * WAVE_W);
    DrawRectangle(x, WAVE_Y, 2, WAVE_H, C(255, 230, 80));
  end;
  DrawRectangleLines(WAVE_X, WAVE_Y, WAVE_W, WAVE_H, C(70, 70, 76));
  DrawText(PChar(SfxNames[Cur]), WAVE_X + 8, WAVE_Y + 6, 20, C(240, 240, 240));
  DrawText(PChar(Format('%s s   %d samples @ %d Hz   (red = clipping)',
    [FormatFloat('0.00', dur, CfgFormat), n, RATE])), WAVE_X + 8, WAVE_Y + 30, 14, C(150, 150, 150));
end;

procedure DrawSliders;
var
  i, col, row: Integer;
  txt: string;
  changedLive: Boolean;
begin
  changedLive := False;
  for i := 0 to NUM_SP - 1 do
  begin
    col := i div 11;
    row := i mod 11;
    if i = SP_WAVE then txt := WaveNames[Round(SfxParams[Cur][i])] else txt := '';
    if Slider(i, WAVE_X + col * (SLIDER_W + 32), SLIDER_Y + row * 30, SLIDER_W, SpInfo[i],
              SfxParams[Cur][i], DefaultSfx[Cur][i], txt) then
      changedLive := True;
  end;
  // live waveform while dragging; the playable sound is rebuilt when the drag ends
  if changedLive then Resynth;
end;

procedure DrawButtons;
var
  y: Integer;
begin
  y := SLIDER_Y + 11 * 30 + 14;
  if Button(WAVE_X, y, 120, 34, 'Play (Space)', True) then PlayCurrent;
  if Button(WAVE_X + 128, y, 80, 34, 'Stop') then StopCurrent;
  if Button(WAVE_X + 216, y, 150, 34, 'Auto-play: ' + BoolToStr(AutoPlay, 'on', 'off'), AutoPlay) then
    AutoPlay := not AutoPlay;
  if Button(WAVE_X + 374, y, 120, 34, 'Reset sound') then ResetCurrent;
  if Button(WAVE_X + 502, y, 100, 34, 'Mutate') then Mutate;
  if Button(WAVE_X + 610, y, 80, 34, 'Copy') then CopyParams;
  if Button(WAVE_X + 698, y, 80, 34, 'Paste') then PasteParams;
  if Button(WAVE_X + 786, y, 120, 34, 'Export WAV') then ExportWav;
  if Button(WAVE_X + 914, y, 98, 34, 'Undo') then DoUndo;

  Inc(y, 44);
  if Button(WAVE_X, y, 150, 34, 'Save (Ctrl+S)') then SaveConfig;
  if Button(WAVE_X + 158, y, 110, 34, 'Reload') then ReloadConfig;
  if Button(WAVE_X + 276, y, 130, 34, 'Reset ALL') then ResetAll;
  if Button(WAVE_X + 414, y, 180, 34, 'Test in game (F5)', True) then TestInGame;
  DrawText(PChar(ConfigPath + BoolToStr(Dirty, '  (unsaved)', '')), WAVE_X + 610, y + 9, 16, C(170, 170, 170));
end;

procedure DrawStatus;
begin
  DrawText('Space play   Up/Down choose sound   Wheel on slider fine-tune   Right-click slider = default   Ctrl+Z undo   Ctrl+C/V copy/paste',
    LIST_X, WIN_H - 26, 16, C(150, 150, 150));
  if MsgTimer > 0 then DrawText(PChar(MsgText), LIST_X, WIN_H - 54, 18, MsgCol);
end;

procedure DrawConfirm;
begin
  DrawRectangle(0, 0, WIN_W, WIN_H, C(0, 0, 0, 160));
  DrawRectangle(390, 290, 500, 180, C(50, 50, 56));
  DrawRectangleLines(390, 290, 500, 180, C(230, 200, 60));
  DrawText('Unsaved sound changes!', 410, 306, 28, C(255, 120, 90));
  DrawText('Save them to sounds.cfg before quitting?', 410, 352, 18, C(230, 230, 230));
  DrawText('[S] Save    [D] Discard    [Esc] Cancel', 410, 420, 18, C(200, 200, 200));
end;

{ ================================================================ main }

procedure HandleKeys;
begin
  if QuitPending then
  begin
    if IsKeyPressed(KEY_S) then
    begin
      if SaveConfig then Quit := True;
      QuitPending := False;
    end
    else if IsKeyPressed(KEY_D) then
      Quit := True
    else if IsKeyPressed(KEY_ESCAPE) then
      QuitPending := False;
    Exit;
  end;
  if CtrlDown then
  begin
    if IsKeyPressed(KEY_Z) or IsKeyPressedRepeat(KEY_Z) then DoUndo;
    if IsKeyPressed(KEY_S) then SaveConfig;
    if IsKeyPressed(KEY_C) then CopyParams;
    if IsKeyPressed(KEY_V) then PasteParams;
    Exit;
  end;
  if IsKeyPressed(KEY_SPACE) then PlayCurrent;
  if IsKeyPressed(KEY_UP) or IsKeyPressedRepeat(KEY_UP) then SelectSound(Cur - 1);
  if IsKeyPressed(KEY_DOWN) or IsKeyPressedRepeat(KEY_DOWN) then SelectSound(Cur + 1);
  if IsKeyPressed(KEY_F5) then TestInGame;
end;

procedure AutoTestStep(frame: Integer);
begin
  case frame of
    5:
      begin
        SelectSound(SFX_SWITCH);
        PushUndo(Cur, SfxParams[Cur]);
        SfxParams[Cur][SP_ARPSEMIS] := 5;
        SfxParams[Cur][SP_TREMDEPTH] := 0.3;
        SfxParams[Cur][SP_TREMRATE] := 9;
        Changed(False);
      end;
    20: TakeScreenshot('sound_autotest.png');
    21:
      begin
        if SaveSfxConfig(ExePath('autotest_sounds.cfg')) then Say('saved');
        Quit := True;
      end;
  end;
end;

procedure RunSoundEditor;
var
  frame: Integer;
  before: TSfxParams;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  AutoTest := ParamStr(1) = '--autotest';
  AutoPlay := True;
  Randomize;

  SetTraceLogLevel(LOG_WARNING);
  SetConfigFlags(FLAG_VSYNC_HINT);
  InitWindow(WIN_W, WIN_H, 'RayDoom Sound Editor');
  SetExitKey(KEY_NULL);
  SetTargetFPS(60);
  InitAudioDevice;
  AudioOK := IsAudioDeviceReady;

  if LoadSfxConfig(ConfigPath) then
    Say('Loaded ' + ConfigPath)
  else
    Say('No ' + SFX_CONFIG_FILE + ' yet - editing the built-in sounds');
  if not AudioOK then Say('No audio device found - you can edit but not listen', False);
  LoadSounds;
  Resynth;

  frame := 0;
  while not Quit do
  begin
    Inc(frame);
    UiBeginFrame;
    UiBlocked := QuitPending;
    if WindowShouldClose then
    begin
      if Dirty then QuitPending := True else Quit := True;
    end;
    MsgTimer := MsgTimer - GetFrameTime;
    if AutoTest then AutoTestStep(frame);
    before := SfxParams[Cur];
    HandleKeys;

    BeginDrawing;
    ClearBackground(C(30, 30, 33));
    DrawRectangle(0, 0, WIN_W, 46, C(52, 52, 56));
    DrawText('RAYDOOM SOUND EDITOR', 16, 13, 22, C(220, 40, 30));
    DrawText('Every sound is synthesized from these parameters - no audio files needed.',
      340, 17, 16, C(170, 170, 170));
    DrawSoundList;
    DrawWaveform;
    DrawSliders;
    DrawButtons;
    DrawStatus;
    if QuitPending then DrawConfirm;
    EndDrawing;

    if EditStarted then PushUndo(Cur, before);
    if EditFinished then Changed(True);
  end;

  StopCurrent;
  UnloadSounds;
  CloseAudioDevice;
  CloseWindow;
end;

end.
