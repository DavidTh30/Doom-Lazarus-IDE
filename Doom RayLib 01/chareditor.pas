unit chareditor;

{ RayDoom character editor: change how the monsters look and fight, and tune the player.
  Settings are saved to characters.cfg, which the game and the map editor load. }

{$mode objfpc}{$H+}

interface

procedure RunCharEditor;

implementation

uses
  SysUtils, Math, Process, raylib, doomparams, doomassets, doomchars, edui;

const
  WIN_W = 1280;
  WIN_H = 800;
  TAB_PLAYER = NUM_MON;          // tabs: one per monster, then the player
  PREV_X = 16;
  PREV_Y = 60;
  PREV_W = 500;
  PREV_H = 480;
  FLOOR_Y = PREV_Y + PREV_H - 40;
  WALL_PX = 380;                 // one wall height (1.0 world units) in preview pixels
  COL1_X = 540;
  COL2_X = 912;
  COL_W = 352;
  MAX_UNDO = 200;
  FrameNames: array[0..4] of string = ('Walk 1', 'Walk 2', 'Attack', 'Pain', 'Dead');

type
  TAnimMode = (amCycle, amWalk, amAttack, amPain, amDead);
  TCharState = record
    M: array[0..NUM_MON - 1] of TMonsterDef;
    P: TPlayerDef;
  end;

const
  AnimNames: array[TAnimMode] of string = ('Cycle', 'Walk', 'Attack', 'Pain', 'Dead');

var
  Tab: Integer = 0;
  Anim: TAnimMode = amCycle;
  Dirty, Quit, QuitPending, AutoTest, LookChanged: Boolean;
  PrevTex: array[0..4] of TTexture2D;
  PrevPix: array[0..4] of TTexPixels;
  BrickTex: TTexture2D;
  UndoBuf: array[0..MAX_UNDO - 1] of TCharState;
  UndoCount: Integer;
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
  Result := ExePath(CHAR_CONFIG_FILE);
end;

function CurrentState: TCharState;
begin
  Result.M := MonDefs;
  Result.P := PlayerDef;
end;

procedure PushUndo(const s: TCharState);
begin
  if UndoCount = MAX_UNDO then
  begin
    Move(UndoBuf[1], UndoBuf[0], SizeOf(TCharState) * (MAX_UNDO - 1));
    Dec(UndoCount);
  end;
  UndoBuf[UndoCount] := s;
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
  MonDefs := UndoBuf[UndoCount].M;
  PlayerDef := UndoBuf[UndoCount].P;
  Dirty := True;
  LookChanged := True;
end;

procedure RebuildPreview;
var
  i: Integer;
begin
  if Tab >= NUM_MON then Exit;
  for i := 0 to 4 do
  begin
    DrawMonster(PrevPix[i], i, MonDefs[Tab]);
    UpdateTexture(PrevTex[i], @PrevPix[i]);
  end;
end;

procedure SelectTab(t: Integer);
begin
  Tab := t;
  LookChanged := True;
end;

procedure ResetTab;
begin
  PushUndo(CurrentState);
  if Tab = TAB_PLAYER then
    PlayerDef := DefaultPlayer
  else
    MonDefs[Tab] := DefaultMonsters[Tab];
  Dirty := True;
  LookChanged := True;
  Say('Reset to defaults');
end;

function SaveConfig: Boolean;
begin
  Result := SaveCharConfig(ConfigPath);
  if Result then
  begin
    Dirty := False;
    Say('Saved ' + ConfigPath);
  end
  else
    Say('Could not save ' + ConfigPath, False);
end;

procedure ReloadConfig;
begin
  ResetCharacters;
  if LoadCharConfig(ConfigPath) then
    Say('Reloaded ' + ConfigPath)
  else
    Say('No ' + CHAR_CONFIG_FILE + ' yet - using built-in characters');
  UndoCount := 0;
  Dirty := False;
  LookChanged := True;
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
    Say('Launched RayDoom with your characters');
  except
    on E: Exception do Say('Could not start RayDoom: ' + E.Message, False);
  end;
  p.Free;
end;

{ ================================================================ monster tab }

function CurrentFrame: Integer;
var
  t: Double;
begin
  t := GetTime;
  case Anim of
    amWalk: if Frac(t * 3) < 0.5 then Result := FR_WALK2 else Result := FR_WALK1;
    amAttack: Result := FR_ATTACK;
    amPain: Result := FR_PAIN;
    amDead: Result := FR_DEAD;
  else
    begin
      // walk 2 s, attack 0.7 s, pain 0.3 s, dead 1.5 s
      t := t - Floor(t / 4.5) * 4.5;
      if t < 2 then
      begin
        if Frac(t * 3) < 0.5 then Result := FR_WALK2 else Result := FR_WALK1;
      end
      else if t < 2.7 then Result := FR_ATTACK
      else if t < 3.0 then Result := FR_PAIN
      else Result := FR_DEAD;
    end;
  end;
end;

procedure DrawPreview;
var
  size, fr, i, x, ty: Integer;
  m: TAnimMode;
  d: TMonsterDef;
begin
  d := MonDefs[Tab];
  // a little room: dark ceiling, floor, and a brick column one wall-height tall for scale
  DrawRectangle(PREV_X, PREV_Y, PREV_W, PREV_H, C(40, 40, 46));
  DrawRectangle(PREV_X, FLOOR_Y, PREV_W, PREV_H - (FLOOR_Y - PREV_Y), C(78, 68, 55));
  DrawTexturePro(BrickTex, Rect(0, 0, 64, 64 * WALL_PX / 120), Rect(PREV_X + 20, FLOOR_Y - WALL_PX, 120, WALL_PX),
    Vec2(0, 0), 0, WHITE);
  DrawText('wall height', PREV_X + 26, FLOOR_Y - WALL_PX - 18, 14, C(170, 170, 170));

  fr := CurrentFrame;
  size := Round(WALL_PX * d[MP_SCALE]);
  DrawEllipse(PREV_X + 330, FLOOR_Y, size * 0.32, 8, C(0, 0, 0, 90));
  DrawTexturePro(PrevTex[fr], Rect(0, 0, 64, 64), Rect(PREV_X + 330 - size div 2, FLOOR_Y - size, size, size),
    Vec2(0, 0), 0, WHITE);
  DrawText(PChar(MonNames[Tab] + ' - ' + FrameNames[fr]), PREV_X + 160, PREV_Y + 10, 20, C(235, 235, 235));
  DrawRectangleLines(PREV_X, PREV_Y, PREV_W, PREV_H, C(70, 70, 76));

  ty := PREV_Y + PREV_H + 10;
  for m := Low(TAnimMode) to High(TAnimMode) do
    if Button(PREV_X + Ord(m) * 101, ty, 95, 30, AnimNames[m], m = Anim) then Anim := m;

  Inc(ty, 40);
  for i := 0 to 4 do
  begin
    x := PREV_X + i * 101;
    DrawRectangle(x, ty, 95, 95, C(52, 52, 58));
    if i = fr then DrawRectangleLines(x, ty, 95, 95, C(255, 220, 60));
    DrawTexturePro(PrevTex[i], Rect(0, 0, 64, 64), Rect(x + 8, ty + 4, 79, 79), Vec2(0, 0), 0, WHITE);
    DrawText(PChar(FrameNames[i]), x + (95 - MeasureText(PChar(FrameNames[i]), 14)) div 2, ty + 80, 14, C(200, 200, 200));
  end;
end;

procedure DrawMonsterSliders;
var
  i, x, y: Integer;
  txt: string;
  d: TMonsterDef;
  avgPellet, shots, dps, cd: Single;
begin
  SectionTitle('COMBAT', COL1_X, 60);
  SectionTitle('LOOK', COL2_X, 60);
  // colour swatches next to the LOOK title
  d := MonDefs[Tab];
  DrawRectangle(COL2_X + 70, 62, 40, 18, C(Round(d[MP_BODYR]), Round(d[MP_BODYG]), Round(d[MP_BODYB])));
  DrawRectangle(COL2_X + 116, 62, 18, 18, C(Round(d[MP_EYER]), Round(d[MP_EYEG]), Round(d[MP_EYEB])));
  for i := 0 to NUM_MP - 1 do
  begin
    if i < MP_FIRST_LOOK then
    begin
      x := COL1_X;
      y := 90 + i * 30;
    end
    else
    begin
      x := COL2_X;
      y := 90 + (i - MP_FIRST_LOOK) * 30;
    end;
    txt := '';
    if i = MP_RANGED then
    begin
      if MonDefs[Tab][i] >= 0.5 then txt := 'Ranged' else txt := 'Melee';
    end
    else if i = MP_SPIKES then
    begin
      if MonDefs[Tab][i] >= 0.5 then txt := 'On' else txt := 'Off';
    end;
    if Slider(Tab * 100 + i, x, y, COL_W, MpInfo[i], MonDefs[Tab][i], DefaultMonsters[Tab][i], txt) then
    begin
      Dirty := True;
      if (i >= MP_FIRST_LOOK) or (i = MP_RANGED) then LookChanged := True;
    end;
  end;

  // quick balance numbers
  d := MonDefs[Tab];
  y := 90 + 12 * 30 + 16;
  SectionTitle('BALANCE', COL1_X, y);
  avgPellet := (PlayerDef[PP_PDMGMIN] + PlayerDef[PP_PDMGMAX]) / 2;
  shots := d[MP_HP] / Max(1, avgPellet * PlayerDef[PP_PELLETS]);
  if d[MP_RANGED] >= 0.5 then cd := d[MP_COOLDOWN] * 1.5 + 0.7 else cd := d[MP_COOLDOWN] + 0.45;
  dps := (d[MP_DMGMIN] + d[MP_DMGMAX]) / 2 / Max(0.1, cd);
  DrawText(PChar(Format('Point-blank shotgun blasts to kill: %s', [FormatFloat('0.0', shots, CfgFormat)])),
    COL1_X, y + 28, 16, C(220, 220, 220));
  DrawText(PChar(Format('Damage per second to the player: ~%s', [FormatFloat('0.0', dps, CfgFormat)])),
    COL1_X, y + 50, 16, C(220, 220, 220));
  if d[MP_DMGMIN] > d[MP_DMGMAX] then
    DrawText('! Damage min is above damage max', COL1_X, y + 72, 16, C(255, 140, 100))
  else if (d[MP_RANGED] < 0.5) and (d[MP_RANGE] > 3) then
    DrawText('! Melee range above 3 lets it bite from afar', COL1_X, y + 72, 16, C(255, 140, 100));
end;

{ ================================================================ player tab }

procedure DrawSpread;
var
  cx, cy, r, i, hitW: Integer;
  spread, frac2, frac5, frac10, a: Single;
  seed: Cardinal;

  function HitFraction(dist: Single): Single;
  begin
    if spread <= 0.0001 then Exit(1);
    Result := Min(1, ArcTan(0.32 / dist) / (spread / 2));
  end;

begin
  DrawRectangle(PREV_X, PREV_Y, PREV_W, PREV_H, C(40, 40, 46));
  DrawRectangleLines(PREV_X, PREV_Y, PREV_W, PREV_H, C(70, 70, 76));
  DrawText('Shotgun spread at 5 units', PREV_X + 12, PREV_Y + 10, 20, C(235, 235, 235));
  spread := PlayerDef[PP_SPREAD];
  cx := PREV_X + PREV_W div 2;
  cy := PREV_Y + 250;
  // 1 world unit = 160 px at this distance; an imp is about 0.64 units wide to the shotgun
  hitW := Round(0.64 * 160);
  DrawRectangle(cx - hitW div 2, cy - 110, hitW, 220, C(140, 88, 52, 120));
  DrawText('monster', cx - 30, cy + 116, 16, C(200, 160, 120));
  r := Round(Tan(spread / 2) * 5 * 160);
  DrawRectangle(cx - r, cy - 2, 2 * r, 4, C(255, 220, 60, 120));
  // a sample volley (fixed per second so it does not flicker)
  seed := Cardinal(Trunc(GetTime)) * 2654435761;
  for i := 1 to Round(PlayerDef[PP_PELLETS]) do
  begin
    seed := seed * 1664525 + 1013904223;
    a := ((seed shr 8) / 16777216.0 - 0.5) * spread;
    seed := seed * 1664525 + 1013904223;
    DrawCircle(cx + Round(Tan(a) * 5 * 160), cy - 60 + Integer((seed shr 8) mod 120), 5, C(255, 240, 160));
  end;
  frac2 := HitFraction(2);
  frac5 := HitFraction(5);
  frac10 := HitFraction(10);
  DrawText(PChar(Format('Pellets on target:  2u %d%%   5u %d%%   10u %d%%',
    [Round(frac2 * 100), Round(frac5 * 100), Round(frac10 * 100)])), PREV_X + 12, PREV_Y + PREV_H - 60, 16, C(220, 220, 220));
  DrawText(PChar(Format('Average damage per blast at 5 units: %s', [FormatFloat('0',
    frac5 * PlayerDef[PP_PELLETS] * (PlayerDef[PP_PDMGMIN] + PlayerDef[PP_PDMGMAX]) / 2, CfgFormat)])),
    PREV_X + 12, PREV_Y + PREV_H - 36, 16, C(220, 220, 220));
end;

procedure DrawPlayerSliders;
var
  i: Integer;
begin
  SectionTitle('PLAYER', COL1_X, 60);
  for i := 0 to NUM_PP - 1 do
    if Slider(1000 + i, COL1_X, 90 + i * 30, 720, PpInfo[i], PlayerDef[i], DefaultPlayer[i]) then
      Dirty := True;
  if PlayerDef[PP_HEALTH] > PlayerDef[PP_MAXHEALTH] then
    DrawText('! Start health is above max health', COL1_X, 90 + NUM_PP * 30 + 10, 16, C(255, 140, 100));
  if PlayerDef[PP_PDMGMIN] > PlayerDef[PP_PDMGMAX] then
    DrawText('! Pellet damage min is above max', COL1_X, 90 + NUM_PP * 30 + 32, 16, C(255, 140, 100));
end;

{ ================================================================ frame }

procedure DrawTopBar;
var
  i: Integer;
begin
  DrawRectangle(0, 0, WIN_W, 46, C(52, 52, 56));
  DrawText('RAYDOOM CHARACTER EDITOR', 16, 13, 22, C(220, 40, 30));
  for i := 0 to NUM_MON - 1 do
    if Button(370 + i * 100, 8, 94, 30, MonNames[i], Tab = i) then SelectTab(i);
  if Button(370 + NUM_MON * 100, 8, 94, 30, 'Player', Tab = TAB_PLAYER) then SelectTab(TAB_PLAYER);
  if Button(690, 8, 80, 30, 'Undo') then DoUndo;
  if Button(776, 8, 90, 30, 'Reset tab') then ResetTab;
  if Button(872, 8, 80, 30, 'Reload') then ReloadConfig;
  if Button(958, 8, 130, 30, 'Save (Ctrl+S)') then SaveConfig;
  if Button(1094, 8, 170, 30, 'Test in game (F5)', True) then TestInGame;
end;

procedure DrawStatus;
begin
  DrawText(PChar('Drag sliders   Wheel fine-tune   Right-click = default   Ctrl+Z undo   ' +
    ConfigPath + BoolToStr(Dirty, '  (unsaved)', '')), PREV_X, WIN_H - 26, 15, C(150, 150, 150));
  if MsgTimer > 0 then DrawText(PChar(MsgText), PREV_X, WIN_H - 52, 18, MsgCol);
end;

procedure DrawConfirm;
begin
  DrawRectangle(0, 0, WIN_W, WIN_H, C(0, 0, 0, 160));
  DrawRectangle(390, 290, 500, 180, C(50, 50, 56));
  DrawRectangleLines(390, 290, 500, 180, C(230, 200, 60));
  DrawText('Unsaved character changes!', 410, 306, 28, C(255, 120, 90));
  DrawText('Save them to characters.cfg before quitting?', 410, 352, 18, C(230, 230, 230));
  DrawText('[S] Save    [D] Discard    [Esc] Cancel', 410, 420, 18, C(200, 200, 200));
end;

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
    Exit;
  end;
  if IsKeyPressed(KEY_F5) then TestInGame;
  if IsKeyPressed(KEY_TAB) then SelectTab((Tab + 1) mod (NUM_MON + 1));
end;

procedure AutoTestStep(frame: Integer);
begin
  case frame of
    3:
      begin
        // a green, horned, ranged demon
        SelectTab(MON_DEMON);
        MonDefs[MON_DEMON][MP_BODYR] := 90;
        MonDefs[MON_DEMON][MP_BODYG] := 170;
        MonDefs[MON_DEMON][MP_BODYB] := 80;
        MonDefs[MON_DEMON][MP_HORNS] := 8;
        MonDefs[MON_DEMON][MP_RANGED] := 1;
        Anim := amAttack;
        LookChanged := True;
      end;
    20: TakeScreenshot('char_autotest_1.png');
    21: SelectTab(TAB_PLAYER);
    30: TakeScreenshot('char_autotest_2.png');
    31:
      begin
        SaveCharConfig(ExePath('autotest_characters.cfg'));
        Quit := True;
      end;
  end;
end;

procedure RunCharEditor;
var
  i, frame: Integer;
  img: TImage;
  before: TCharState;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  AutoTest := ParamStr(1) = '--autotest';

  SetTraceLogLevel(LOG_WARNING);
  SetConfigFlags(FLAG_VSYNC_HINT);
  InitWindow(WIN_W, WIN_H, 'RayDoom Character Editor');
  SetExitKey(KEY_NULL);
  SetTargetFPS(60);

  if LoadCharConfig(ConfigPath) then
    Say('Loaded ' + ConfigPath)
  else
    Say('No ' + CHAR_CONFIG_FILE + ' yet - editing the built-in characters');
  GenerateTextures;
  img := GenImageColor(TEX_SIZE, TEX_SIZE, BLACK);
  for i := 0 to 4 do PrevTex[i] := LoadTextureFromImage(img);
  BrickTex := LoadTextureFromImage(img);
  UnloadImage(img);
  UpdateTexture(BrickTex, @WallTex[TEX_BRICK]);
  LookChanged := True;

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
    before := CurrentState;
    HandleKeys;
    if LookChanged then
    begin
      RebuildPreview;
      LookChanged := False;
    end;

    BeginDrawing;
    ClearBackground(C(30, 30, 33));
    DrawTopBar;
    if Tab = TAB_PLAYER then
    begin
      DrawSpread;
      DrawPlayerSliders;
    end
    else
    begin
      DrawPreview;
      DrawMonsterSliders;
    end;
    DrawStatus;
    if QuitPending then DrawConfirm;
    EndDrawing;

    if EditStarted then PushUndo(before);
  end;

  for i := 0 to 4 do UnloadTexture(PrevTex[i]);
  UnloadTexture(BrickTex);
  CloseWindow;
end;

end.
