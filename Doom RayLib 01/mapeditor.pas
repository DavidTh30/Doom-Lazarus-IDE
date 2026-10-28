unit mapeditor;

{ RayDoom map editor: paint walls, doors, monsters and items on the 32x24 grid,
  check the map for problems, save it and launch the game on it (F5). }

{$mode objfpc}{$H+}

interface

procedure RunEditor;

implementation

uses
  SysUtils, Math, Process, raylib, doomparams, doomassets, doomchars, doommap;

const
  WIN_W = 1280;
  WIN_H = 800;
  CELL = 26;
  GRID_X = 16;
  GRID_Y = 60;
  GRID_R = GRID_X + MAP_W * CELL;
  GRID_B = GRID_Y + MAP_H * CELL;
  PANEL_X = 868;
  MAX_UNDO = 200;
  MAX_OBJECTS = 200;     // the game keeps 256 entity slots, the rest is for projectiles/effects

  NUM_TILES = 13;
  TileChars: array[0..NUM_TILES - 1] of Char =
    ('.', '#', '%', '&', '=', 'D', 'X', 'P', 'i', 'd', 'h', 'a', 'l');
  TileNames: array[0..NUM_TILES - 1] of string =
    ('Floor', 'Brick', 'Stone', 'Tech', 'Wood', 'Door', 'Exit', 'Player', 'Imp', 'Demon', 'Medikit', 'Shells', 'Lamp');
  TileKeyNames: array[0..NUM_TILES - 1] of string =
    ('`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=');
  TileKeys: array[0..NUM_TILES - 1] of Integer =
    (KEY_GRAVE, KEY_ONE, KEY_ONE + 1, KEY_ONE + 2, KEY_ONE + 3, KEY_ONE + 4, KEY_ONE + 5,
     KEY_ONE + 6, KEY_ONE + 7, KEY_ONE + 8, KEY_ZERO, KEY_MINUS, KEY_EQUAL);

type
  TTool = (tlPencil, tlRoom, tlArea, tlBucket, tlPicker);
  TPending = (paNone, paNew, paOpen, paQuit);

const
  ToolNames: array[TTool] of string = ('Pencil', 'Room', 'Area', 'Bucket', 'Picker');
  ToolKeyNames: array[TTool] of string = ('B', 'R', 'T', 'F', 'I');
  ToolHelp: array[TTool] of string = (
    'Pencil: drag to paint cells',
    'Room: drag a rectangle outline (walls of a room)',
    'Area: drag a filled rectangle',
    'Bucket: flood-fill connected cells of the same tile',
    'Picker: click a cell to select its tile');

var
  Grid, StrokeBefore: TMapGrid;
  UndoBuf, RedoBuf: array[0..MAX_UNDO - 1] of TMapGrid;
  UndoCount, RedoCount: Integer;
  CurTile: Integer = 1;
  Tool: TTool = tlPencil;
  Dirty, ShowGrid, Quit, EditingName, Dragging, AutoTest: Boolean;
  FileName, EditBuf, LastTitle: string;
  DragBtn, DragX0, DragY0, LastX, LastY: Integer;
  MsgText: string;
  MsgTimer: Single;
  MsgCol: TColor;
  Pending: TPending = paNone;
  WallT: array[0..NUM_TEX - 1] of TTexture2D;
  SprT: array[0..NUM_SPR - 1] of TTexture2D;
  MouseX, MouseY: Integer;

  // results of the map check, refreshed every frame
  Issues: array of string;
  CntImp, CntDemon, CntMed, CntAmmo, CntLamp, CntDoor, CntObjects: Integer;

{ ================================================================ helpers }

function C(r, g, b: Integer; a: Integer = 255): TColor; inline;
begin
  Result := ColorRGBA(r, g, b, a);
end;

procedure Say(const s: string; good: Boolean = True);
begin
  MsgText := s;
  MsgTimer := 4;
  if good then MsgCol := C(120, 230, 120) else MsgCol := C(255, 110, 90);
end;

function TileIndex(ch: Char): Integer;
var
  i: Integer;
begin
  for i := 0 to NUM_TILES - 1 do
    if TileChars[i] = ch then Exit(i);
  Result := 0;
end;

function InGrid(cx, cy: Integer): Boolean; inline;
begin
  Result := (cx >= 0) and (cy >= 0) and (cx < MAP_W) and (cy < MAP_H);
end;

function MouseIn(x, y, w, h: Integer): Boolean;
begin
  Result := (MouseX >= x) and (MouseY >= y) and (MouseX < x + w) and (MouseY < y + h);
end;

function CtrlDown: Boolean;
begin
  Result := IsKeyDown(KEY_LEFT_CONTROL) or IsKeyDown(KEY_RIGHT_CONTROL);
end;

function TexFromPixels(var p: TTexPixels): TTexture2D;
var
  img: TImage;
begin
  img := GenImageColor(TEX_SIZE, TEX_SIZE, BLACK);
  Result := LoadTextureFromImage(img);
  UnloadImage(img);
  UpdateTexture(Result, @p);
end;

procedure UpdateTitle;
var
  s: string;
begin
  s := 'RayDoom Map Editor - ' + FileName;
  if Dirty then s := s + ' *';
  if s <> LastTitle then
  begin
    LastTitle := s;
    SetWindowTitle(PChar(s));
  end;
end;

{ ================================================================ editing }

procedure PushUndo(const g: TMapGrid);
begin
  if UndoCount = MAX_UNDO then
  begin
    Move(UndoBuf[1], UndoBuf[0], SizeOf(TMapGrid) * (MAX_UNDO - 1));
    Dec(UndoCount);
  end;
  UndoBuf[UndoCount] := g;
  Inc(UndoCount);
  RedoCount := 0;
end;

procedure DoUndo;
begin
  if UndoCount = 0 then
  begin
    Say('Nothing to undo', False);
    Exit;
  end;
  RedoBuf[RedoCount] := Grid;
  Inc(RedoCount);
  Dec(UndoCount);
  Grid := UndoBuf[UndoCount];
  Dirty := True;
end;

procedure DoRedo;
begin
  if RedoCount = 0 then
  begin
    Say('Nothing to redo', False);
    Exit;
  end;
  UndoBuf[UndoCount] := Grid;
  Inc(UndoCount);
  Dec(RedoCount);
  Grid := RedoBuf[RedoCount];
  Dirty := True;
end;

// Start of an edit: remember the grid so the whole edit becomes one undo step
procedure BeginEdit;
begin
  StrokeBefore := Grid;
end;

procedure EndEdit;
begin
  if not CompareMem(@StrokeBefore, @Grid, SizeOf(TMapGrid)) then
  begin
    PushUndo(StrokeBefore);
    Dirty := True;
  end;
end;

procedure SetCell(cx, cy: Integer; ch: Char);
var
  x, y: Integer;
begin
  if not InGrid(cx, cy) or (Grid[cx, cy] = ch) then Exit;
  if ch = 'P' then
    // only one player start: placing a new one moves it
    for y := 0 to MAP_H - 1 do
      for x := 0 to MAP_W - 1 do
        if Grid[x, y] = 'P' then Grid[x, y] := '.';
  Grid[cx, cy] := ch;
end;

procedure PaintLine(x0, y0, x1, y1: Integer; ch: Char);
var
  dx, dy, sx, sy, err, e2: Integer;
begin
  dx := Abs(x1 - x0);
  dy := -Abs(y1 - y0);
  if x0 < x1 then sx := 1 else sx := -1;
  if y0 < y1 then sy := 1 else sy := -1;
  err := dx + dy;
  while True do
  begin
    SetCell(x0, y0, ch);
    if (x0 = x1) and (y0 = y1) then Break;
    e2 := 2 * err;
    if e2 >= dy then begin Inc(err, dy); Inc(x0, sx); end;
    if e2 <= dx then begin Inc(err, dx); Inc(y0, sy); end;
  end;
end;

procedure FillRectCells(x0, y0, x1, y1: Integer; ch: Char; outline: Boolean);
var
  x, y, t: Integer;
begin
  if x0 > x1 then begin t := x0; x0 := x1; x1 := t; end;
  if y0 > y1 then begin t := y0; y0 := y1; y1 := t; end;
  if ch = 'P' then
  begin
    SetCell(x1, y1, ch);
    Exit;
  end;
  for y := y0 to y1 do
    for x := x0 to x1 do
      if not outline or (x = x0) or (x = x1) or (y = y0) or (y = y1) then
        SetCell(x, y, ch);
end;

procedure FloodFill(cx, cy: Integer; ch: Char);
var
  stack: array of Integer;
  sp, x, y, p: Integer;
  target: Char;
begin
  if not InGrid(cx, cy) then Exit;
  target := Grid[cx, cy];
  if target = ch then Exit;
  if ch = 'P' then
  begin
    SetCell(cx, cy, ch);
    Exit;
  end;
  SetLength(stack, MAP_W * MAP_H * 4 + 4);
  sp := 0;
  stack[sp] := cx + cy * MAP_W;
  Inc(sp);
  while sp > 0 do
  begin
    Dec(sp);
    p := stack[sp];
    x := p mod MAP_W;
    y := p div MAP_W;
    if Grid[x, y] <> target then Continue;
    Grid[x, y] := ch;
    if (x > 0) and (Grid[x - 1, y] = target) then begin stack[sp] := p - 1; Inc(sp); end;
    if (x < MAP_W - 1) and (Grid[x + 1, y] = target) then begin stack[sp] := p + 1; Inc(sp); end;
    if (y > 0) and (Grid[x, y - 1] = target) then begin stack[sp] := p - MAP_W; Inc(sp); end;
    if (y < MAP_H - 1) and (Grid[x, y + 1] = target) then begin stack[sp] := p + MAP_W; Inc(sp); end;
  end;
end;

{ ================================================================ file actions }

function SaveMap: Boolean;
begin
  Result := SaveMapFile(MapPath(FileName), Grid);
  if Result then
  begin
    Dirty := False;
    Say('Saved ' + MapPath(FileName));
  end
  else
    Say('Could not save ' + MapPath(FileName), False);
end;

procedure OpenMap;
var
  g: TMapGrid;
begin
  if LoadMapFile(MapPath(FileName), g) then
  begin
    PushUndo(Grid);
    Grid := g;
    Dirty := False;
    Say('Opened ' + MapPath(FileName));
  end
  else
    Say('File not found: ' + MapPath(FileName), False);
end;

procedure NewMap;
begin
  PushUndo(Grid);
  EmptyGrid(Grid);
  FileName := 'untitled.map';
  Dirty := False;
  Say('New map');
end;

procedure PerformAction(a: TPending);
begin
  case a of
    paNew: NewMap;
    paOpen: OpenMap;
    paQuit: Quit := True;
  end;
  Pending := paNone;
end;

// Actions that would throw away unsaved work ask first
procedure RequestAction(a: TPending);
begin
  if Dirty then Pending := a else PerformAction(a);
end;

procedure TestPlay;
var
  exe: string;
  p: TProcess;
begin
  if not SaveMap then Exit;
  exe := ExtractFilePath(ParamStr(0)) + 'RayDoom.exe';
  if not FileExists(exe) then
  begin
    Say('RayDoom.exe not found - build RayDoom.lpi first', False);
    Exit;
  end;
  p := TProcess.Create(nil);
  try
    p.Executable := exe;
    p.Parameters.Add(MapPath(FileName));
    p.CurrentDirectory := ExtractFilePath(exe);
    p.Execute;
    Say('Launched RayDoom with ' + ExtractFileName(FileName));
  except
    on E: Exception do Say('Could not start RayDoom: ' + E.Message, False);
  end;
  p.Free;
end;

procedure CommitFileName;
var
  s: string;
begin
  EditingName := False;
  s := Trim(EditBuf);
  if s = '' then Exit;
  if ExtractFileExt(s) = '' then s := s + '.map';
  FileName := s;
end;

{ ================================================================ map check }

procedure AnalyzeMap;
var
  x, y, sp, p, px, py, borderOpen, badDoors, unreachable, firstBX, firstBY, firstDX, firstDY: Integer;
  ch: Char;
  players, exits, exitsReachable: Integer;
  seen: array[0..MAP_W - 1, 0..MAP_H - 1] of Boolean;
  stack: array of Integer;

  procedure Add(const s: string);
  begin
    SetLength(Issues, Length(Issues) + 1);
    Issues[High(Issues)] := s;
  end;

  function Passable(cx, cy: Integer): Boolean;
  begin
    Result := InGrid(cx, cy) and not IsWallTile(Grid[cx, cy]);
  end;

  function Reached(cx, cy: Integer): Boolean;
  begin
    Result := InGrid(cx, cy) and seen[cx, cy];
  end;

begin
  Issues := nil;
  CntImp := 0; CntDemon := 0; CntMed := 0; CntAmmo := 0; CntLamp := 0; CntDoor := 0;
  players := 0; exits := 0; borderOpen := 0; badDoors := 0;
  firstBX := 0; firstBY := 0; firstDX := 0; firstDY := 0;
  px := -1; py := -1;

  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
    begin
      ch := Grid[x, y];
      case ch of
        'i': Inc(CntImp);
        'd': Inc(CntDemon);
        'h': Inc(CntMed);
        'a': Inc(CntAmmo);
        'l': Inc(CntLamp);
        'X': Inc(exits);
        'P': begin Inc(players); px := x; py := y; end;
        'D':
          begin
            Inc(CntDoor);
            if not ((IsWallTile(GridCell(Grid, x - 1, y)) and IsWallTile(GridCell(Grid, x + 1, y))) or
                    (IsWallTile(GridCell(Grid, x, y - 1)) and IsWallTile(GridCell(Grid, x, y + 1)))) then
            begin
              if badDoors = 0 then begin firstDX := x; firstDY := y; end;
              Inc(badDoors);
            end;
          end;
      end;
      if ((x = 0) or (y = 0) or (x = MAP_W - 1) or (y = MAP_H - 1)) and not IsWallTile(ch) then
      begin
        if borderOpen = 0 then begin firstBX := x; firstBY := y; end;
        Inc(borderOpen);
      end;
    end;
  CntObjects := CntImp + CntDemon + CntMed + CntAmmo + CntLamp;

  if players = 0 then Add('No player start (P)');
  if players > 1 then Add(Format('%d player starts - only one is used', [players]));
  if exits = 0 then Add('No EXIT switch (X) - level cannot be finished');
  if borderOpen > 0 then
    Add(Format('Map edge is open at %d,%d (%d cells)', [firstBX, firstBY, borderOpen]));
  if badDoors > 0 then
    Add(Format('Door at %d,%d needs walls on 2 opposite sides', [firstDX, firstDY]));
  if CntObjects > MAX_OBJECTS then
    Add(Format('Too many objects: %d (max %d)', [CntObjects, MAX_OBJECTS]));
  if CntImp + CntDemon = 0 then Add('No monsters - a bit quiet?');

  // flood fill from the player through floor and doors
  if px >= 0 then
  begin
    FillChar(seen, SizeOf(seen), 0);
    SetLength(stack, MAP_W * MAP_H * 4 + 4);
    sp := 0;
    stack[sp] := px + py * MAP_W;
    Inc(sp);
    while sp > 0 do
    begin
      Dec(sp);
      p := stack[sp];
      x := p mod MAP_W;
      y := p div MAP_W;
      if seen[x, y] then Continue;
      seen[x, y] := True;
      if Passable(x - 1, y) and not seen[x - 1, y] then begin stack[sp] := p - 1; Inc(sp); end;
      if Passable(x + 1, y) and not seen[x + 1, y] then begin stack[sp] := p + 1; Inc(sp); end;
      if Passable(x, y - 1) and not seen[x, y - 1] then begin stack[sp] := p - MAP_W; Inc(sp); end;
      if Passable(x, y + 1) and not seen[x, y + 1] then begin stack[sp] := p + MAP_W; Inc(sp); end;
    end;

    exitsReachable := 0;
    unreachable := 0;
    for y := 0 to MAP_H - 1 do
      for x := 0 to MAP_W - 1 do
      begin
        ch := Grid[x, y];
        if (ch = 'X') and (Reached(x - 1, y) or Reached(x + 1, y) or Reached(x, y - 1) or Reached(x, y + 1)) then
          Inc(exitsReachable);
        if (ch in ['i', 'd', 'h', 'a']) and not seen[x, y] then
          Inc(unreachable);
      end;
    if (exits > 0) and (exitsReachable = 0) then
      Add('The player cannot reach any EXIT switch');
    if unreachable > 0 then
      Add(Format('%d monsters/items are unreachable', [unreachable]));
  end;
end;

{ ================================================================ drawing }

function SpriteFor(ch: Char; out src: TRectangle): Integer;
begin
  src := Rect(0, 0, TEX_SIZE, TEX_SIZE);
  case ch of
    'i': Result := SPR_IMP + FR_WALK1;
    'd': Result := SPR_DEMON + FR_WALK1;
    'h': begin Result := SPR_MEDKIT; src := Rect(8, 16, 48, 48); end;
    'a': begin Result := SPR_AMMO; src := Rect(8, 16, 48, 48); end;
    'l': Result := SPR_LAMP;
  else
    Result := -1;
  end;
end;

function WallTexFor(ch: Char): Integer;
begin
  case ch of
    '#': Result := TEX_BRICK;
    '%': Result := TEX_STONE;
    '&': Result := TEX_TECH;
    '=': Result := TEX_WOOD;
    'D': Result := TEX_DOOR;
    'X': Result := TEX_EXIT;
  else
    Result := -1;
  end;
end;

procedure DrawTile(ch: Char; x, y, size: Integer; alpha: Integer = 255);
var
  t, cx, cy: Integer;
  src: TRectangle;
  tint: TColor;
begin
  tint := C(255, 255, 255, alpha);
  DrawRectangle(x, y, size, size, C(38, 38, 42, alpha));
  t := WallTexFor(ch);
  if t >= 0 then
  begin
    DrawTexturePro(WallT[t], Rect(0, 0, TEX_SIZE, TEX_SIZE), Rect(x, y, size, size), Vec2(0, 0), 0, tint);
    Exit;
  end;
  t := SpriteFor(ch, src);
  if t >= 0 then
  begin
    DrawTexturePro(SprT[t], src, Rect(x, y, size, size), Vec2(0, 0), 0, tint);
    Exit;
  end;
  if ch = 'P' then
  begin
    cx := x + size div 2;
    cy := y + size div 2;
    DrawCircle(cx, cy, size * 0.36, C(60, 220, 60, alpha));
    // the player always starts facing east
    DrawTriangle(Vec2(x + size * 0.9, cy), Vec2(x + size * 0.55, cy - size * 0.22),
                 Vec2(x + size * 0.55, cy + size * 0.22), C(20, 90, 20, alpha));
  end;
end;

procedure DrawDoorMarker(cx, cy: Integer);
var
  x, y: Integer;
  horiz, vert: Boolean;
begin
  x := GRID_X + cx * CELL;
  y := GRID_Y + cy * CELL;
  horiz := IsWallTile(GridCell(Grid, cx - 1, cy)) and IsWallTile(GridCell(Grid, cx + 1, cy));
  vert := IsWallTile(GridCell(Grid, cx, cy - 1)) and IsWallTile(GridCell(Grid, cx, cy + 1));
  if horiz then
    DrawRectangle(x, y + CELL div 2 - 2, CELL, 4, C(255, 220, 40))
  else if vert then
    DrawRectangle(x + CELL div 2 - 2, y, 4, CELL, C(255, 220, 40))
  else
  begin
    DrawRectangleLines(x, y, CELL, CELL, C(255, 40, 40));
    DrawRectangleLines(x + 1, y + 1, CELL - 2, CELL - 2, C(255, 40, 40));
  end;
end;

function Button(x, y, w, h: Integer; const lbl: string; active: Boolean = False): Boolean;
var
  hot: Boolean;
  col: TColor;
begin
  hot := MouseIn(x, y, w, h) and (Pending = paNone);
  if active then col := C(170, 35, 28)
  else if hot then col := C(88, 88, 94)
  else col := C(60, 60, 66);
  DrawRectangle(x, y, w, h, col);
  DrawRectangle(x, y, w, 2, C(120, 120, 128));
  DrawRectangleLines(x, y, w, h, C(20, 20, 22));
  DrawText(PChar(lbl), x + (w - MeasureText(PChar(lbl), 18)) div 2, y + (h - 18) div 2, 18, C(235, 235, 235));
  Result := hot and IsMouseButtonPressed(MOUSE_BUTTON_LEFT);
end;

procedure DrawTopBar;
var
  shown: string;
begin
  DrawRectangle(0, 0, WIN_W, 46, C(52, 52, 56));
  DrawRectangle(0, 46, WIN_W, 2, C(20, 20, 20));
  DrawText('RAYDOOM MAP EDITOR', 16, 13, 22, C(220, 40, 30));

  DrawText('File:', 290, 15, 18, C(200, 200, 200));
  if EditingName then
  begin
    DrawRectangle(338, 9, 300, 28, C(20, 20, 24));
    DrawRectangleLines(338, 9, 300, 28, C(255, 200, 60));
    shown := EditBuf;
    if Frac(GetTime * 2) < 0.5 then shown := shown + '_';
  end
  else
  begin
    DrawRectangle(338, 9, 300, 28, C(32, 32, 36));
    DrawRectangleLines(338, 9, 300, 28, C(90, 90, 96));
    shown := FileName;
    if Dirty then shown := shown + ' *';
  end;
  DrawText(PChar(shown), 346, 15, 18, C(240, 240, 240));
  if (not EditingName) and MouseIn(338, 9, 300, 28) and IsMouseButtonPressed(MOUSE_BUTTON_LEFT) and (Pending = paNone) then
  begin
    EditingName := True;
    EditBuf := FileName;
  end;

  if Button(656, 8, 70, 30, 'New') then RequestAction(paNew);
  if Button(732, 8, 70, 30, 'Open') then RequestAction(paOpen);
  if Button(808, 8, 70, 30, 'Save') then SaveMap;
  if Button(884, 8, 110, 30, 'Test (F5)', True) then TestPlay;
  if Button(1010, 8, 70, 30, 'Undo') then DoUndo;
  if Button(1086, 8, 70, 30, 'Redo') then DoRedo;
  if Button(1162, 8, 100, 30, 'Grid (G)', ShowGrid) then ShowGrid := not ShowGrid;
end;

procedure DrawGrid;
var
  x, y, cx, cy, x0, y0, x1, y1: Integer;
  hover: Boolean;
begin
  DrawRectangle(GRID_X - 4, GRID_Y - 4, MAP_W * CELL + 8, MAP_H * CELL + 8, C(15, 15, 17));
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
      DrawTile(Grid[x, y], GRID_X + x * CELL, GRID_Y + y * CELL, CELL);
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
      if Grid[x, y] = 'D' then DrawDoorMarker(x, y);

  if ShowGrid then
  begin
    for x := 0 to MAP_W do
      DrawRectangle(GRID_X + x * CELL, GRID_Y, 1, MAP_H * CELL, C(0, 0, 0, 90));
    for y := 0 to MAP_H do
      DrawRectangle(GRID_X, GRID_Y + y * CELL, MAP_W * CELL, 1, C(0, 0, 0, 90));
    for x := 0 to MAP_W - 1 do
      if x mod 4 = 0 then
        DrawText(PChar(IntToStr(x)), GRID_X + x * CELL + 2, GRID_Y - 2 - 12, 10, C(150, 150, 150));
  end;

  cx := Floor((MouseX - GRID_X) / CELL);
  cy := Floor((MouseY - GRID_Y) / CELL);
  hover := InGrid(cx, cy) and (Pending = paNone) and not EditingName;

  // rectangle preview while dragging
  if Dragging and (Tool in [tlRoom, tlArea]) then
  begin
    x0 := Min(DragX0, EnsureRange(cx, 0, MAP_W - 1));
    x1 := Max(DragX0, EnsureRange(cx, 0, MAP_W - 1));
    y0 := Min(DragY0, EnsureRange(cy, 0, MAP_H - 1));
    y1 := Max(DragY0, EnsureRange(cy, 0, MAP_H - 1));
    for y := y0 to y1 do
      for x := x0 to x1 do
        if (Tool = tlArea) or (x = x0) or (x = x1) or (y = y0) or (y = y1) then
        begin
          if DragBtn = MOUSE_BUTTON_RIGHT then
            DrawTile('.', GRID_X + x * CELL, GRID_Y + y * CELL, CELL, 200)
          else
            DrawTile(TileChars[CurTile], GRID_X + x * CELL, GRID_Y + y * CELL, CELL, 200);
        end;
    DrawRectangleLines(GRID_X + x0 * CELL, GRID_Y + y0 * CELL, (x1 - x0 + 1) * CELL, (y1 - y0 + 1) * CELL,
      C(255, 230, 60));
    DrawText(PChar(Format('%d x %d', [x1 - x0 + 1, y1 - y0 + 1])),
      GRID_X + x1 * CELL + CELL + 4, GRID_Y + y1 * CELL, 18, C(255, 230, 60));
  end
  else if hover then
  begin
    if Tool = tlPencil then
      DrawTile(TileChars[CurTile], GRID_X + cx * CELL, GRID_Y + cy * CELL, CELL, 150);
    DrawRectangleLines(GRID_X + cx * CELL, GRID_Y + cy * CELL, CELL, CELL, C(255, 255, 255));
  end;
end;

procedure DrawPanel;
const
  COLS = 3;
  BW = 128;
  BH = 56;
var
  i, x, y, row, col: Integer;
  hot: Boolean;
  tl: TTool;
begin
  DrawRectangle(PANEL_X - 8, 56, WIN_W - PANEL_X, WIN_H - 56, C(44, 44, 48));

  DrawText('TILES', PANEL_X, 64, 20, C(230, 200, 60));
  for i := 0 to NUM_TILES - 1 do
  begin
    row := i div COLS;
    col := i mod COLS;
    x := PANEL_X + col * (BW + 4);
    y := 90 + row * (BH + 4);
    hot := MouseIn(x, y, BW, BH) and (Pending = paNone);
    if i = CurTile then
      DrawRectangle(x, y, BW, BH, C(150, 35, 28))
    else if hot then
      DrawRectangle(x, y, BW, BH, C(78, 78, 84))
    else
      DrawRectangle(x, y, BW, BH, C(58, 58, 64));
    DrawTile(TileChars[i], x + 6, y + 6, 44);
    DrawText(PChar(TileNames[i]), x + 56, y + 10, 18, C(235, 235, 235));
    DrawText(PChar('key ' + TileKeyNames[i]), x + 56, y + 32, 14, C(170, 170, 170));
    if hot and IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
    begin
      CurTile := i;
      if Tool = tlPicker then Tool := tlPencil;
    end;
  end;

  y := 90 + ((NUM_TILES + COLS - 1) div COLS) * (BH + 4) + 8;
  DrawText('TOOLS', PANEL_X, y, 20, C(230, 200, 60));
  Inc(y, 26);
  for tl := Low(TTool) to High(TTool) do
    if Button(PANEL_X + Ord(tl) * 79, y, 75, 34, ToolNames[tl] + ' ' + ToolKeyNames[tl], tl = Tool) then
      Tool := tl;
  Inc(y, 40);
  DrawText(PChar(ToolHelp[Tool]), PANEL_X, y, 15, C(190, 190, 190));

  Inc(y, 28);
  DrawText('STATS', PANEL_X, y, 20, C(230, 200, 60));
  Inc(y, 26);
  DrawText(PChar(Format('Imps %d   Demons %d   Doors %d', [CntImp, CntDemon, CntDoor])), PANEL_X, y, 18, C(220, 220, 220));
  Inc(y, 24);
  DrawText(PChar(Format('Medikits %d   Shells %d   Lamps %d', [CntMed, CntAmmo, CntLamp])), PANEL_X, y, 18, C(220, 220, 220));
  Inc(y, 24);
  DrawText(PChar(Format('Shells needed ~%d, available %d',
    [CntImp + CntDemon * 3, 20 + CntAmmo * 8])), PANEL_X, y, 18, C(220, 220, 220));

  Inc(y, 34);
  DrawText('CHECKS', PANEL_X, y, 20, C(230, 200, 60));
  Inc(y, 26);
  if Length(Issues) = 0 then
    DrawText('Map OK - ready to play!', PANEL_X, y, 18, C(110, 230, 110))
  else
    for i := 0 to Min(High(Issues), 6) do
    begin
      DrawText(PChar('! ' + Issues[i]), PANEL_X, y, 16, C(255, 140, 100));
      Inc(y, 22);
    end;
end;

procedure DrawStatus;
var
  cx, cy: Integer;
  s: string;
begin
  cx := Floor((MouseX - GRID_X) / CELL);
  cy := Floor((MouseY - GRID_Y) / CELL);
  if InGrid(cx, cy) then
    s := Format('Cell %d,%d  -  %s', [cx, cy, TileNames[TileIndex(Grid[cx, cy])]])
  else
    s := '';
  DrawText(PChar(s), GRID_X, GRID_B + 12, 18, C(230, 230, 230));
  DrawText('LMB paint   RMB erase   MMB pick tile   Wheel change tile   Ctrl+Z/Y undo/redo',
    GRID_X, GRID_B + 40, 16, C(160, 160, 160));
  DrawText('Ctrl+S save   Ctrl+O open   Ctrl+N new   F5 save & play   G grid',
    GRID_X, GRID_B + 62, 16, C(160, 160, 160));
  if MsgTimer > 0 then
    DrawText(PChar(MsgText), GRID_X, GRID_B + 88, 18, MsgCol);
end;

procedure DrawConfirm;
var
  what: string;
begin
  DrawRectangle(0, 0, WIN_W, WIN_H, C(0, 0, 0, 160));
  DrawRectangle(390, 290, 500, 200, C(50, 50, 56));
  DrawRectangleLines(390, 290, 500, 200, C(230, 200, 60));
  case Pending of
    paNew: what := 'starting a new map';
    paOpen: what := 'opening ' + FileName;
  else
    what := 'quitting';
  end;
  DrawText('Unsaved changes!', 410, 306, 28, C(255, 120, 90));
  DrawText(PChar('Save before ' + what + '?'), 410, 350, 18, C(230, 230, 230));
  DrawText('[S] Save    [D] Discard    [Esc] Cancel', 410, 440, 18, C(200, 200, 200));
end;

{ ================================================================ input }

procedure HandleKeys;
var
  i, ch: Integer;
  wheel: Single;
begin
  if Pending <> paNone then
  begin
    if IsKeyPressed(KEY_S) then
    begin
      if SaveMap then PerformAction(Pending) else Pending := paNone;
    end
    else if IsKeyPressed(KEY_D) then
      PerformAction(Pending)
    else if IsKeyPressed(KEY_ESCAPE) or IsKeyPressed(KEY_C) then
      Pending := paNone;
    Exit;
  end;

  if EditingName then
  begin
    ch := GetCharPressed;
    while ch > 0 do
    begin
      if (ch >= 32) and (ch < 127) and (Length(EditBuf) < 60) then
        EditBuf := EditBuf + Chr(ch);
      ch := GetCharPressed;
    end;
    if (IsKeyPressed(KEY_BACKSPACE) or IsKeyPressedRepeat(KEY_BACKSPACE)) and (EditBuf <> '') then
      SetLength(EditBuf, Length(EditBuf) - 1);
    if IsKeyPressed(KEY_ENTER) then CommitFileName;
    if IsKeyPressed(KEY_ESCAPE) then EditingName := False;
    if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) and not MouseIn(338, 9, 300, 28) then CommitFileName;
    Exit;
  end;

  if CtrlDown then
  begin
    if IsKeyPressed(KEY_Z) or IsKeyPressedRepeat(KEY_Z) then DoUndo;
    if IsKeyPressed(KEY_Y) or IsKeyPressedRepeat(KEY_Y) then DoRedo;
    if IsKeyPressed(KEY_S) then SaveMap;
    if IsKeyPressed(KEY_O) then RequestAction(paOpen);
    if IsKeyPressed(KEY_N) then RequestAction(paNew);
    Exit;
  end;

  for i := 0 to NUM_TILES - 1 do
    if IsKeyPressed(TileKeys[i]) then CurTile := i;
  if IsKeyPressed(KEY_B) then Tool := tlPencil;
  if IsKeyPressed(KEY_R) then Tool := tlRoom;
  if IsKeyPressed(KEY_T) then Tool := tlArea;
  if IsKeyPressed(KEY_F) then Tool := tlBucket;
  if IsKeyPressed(KEY_I) then Tool := tlPicker;
  if IsKeyPressed(KEY_G) then ShowGrid := not ShowGrid;
  if IsKeyPressed(KEY_F5) then TestPlay;

  wheel := GetMouseWheelMove;
  if wheel > 0 then CurTile := (CurTile + NUM_TILES - 1) mod NUM_TILES;
  if wheel < 0 then CurTile := (CurTile + 1) mod NUM_TILES;
end;

procedure HandleGridMouse;
var
  cx, cy, btn: Integer;
  ch: Char;
begin
  if (Pending <> paNone) or EditingName then
  begin
    Dragging := False;
    Exit;
  end;
  cx := Floor((MouseX - GRID_X) / CELL);
  cy := Floor((MouseY - GRID_Y) / CELL);

  // middle click picks the tile under the cursor
  if IsMouseButtonPressed(MOUSE_BUTTON_MIDDLE) and InGrid(cx, cy) then
    CurTile := TileIndex(Grid[cx, cy]);

  if not Dragging then
  begin
    btn := -1;
    if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then btn := MOUSE_BUTTON_LEFT
    else if IsMouseButtonPressed(MOUSE_BUTTON_RIGHT) then btn := MOUSE_BUTTON_RIGHT;
    if (btn < 0) or not InGrid(cx, cy) then Exit;
    if btn = MOUSE_BUTTON_RIGHT then ch := '.' else ch := TileChars[CurTile];

    case Tool of
      tlPicker:
        begin
          CurTile := TileIndex(Grid[cx, cy]);
          Tool := tlPencil;
        end;
      tlBucket:
        begin
          BeginEdit;
          FloodFill(cx, cy, ch);
          EndEdit;
        end;
    else
      begin
        BeginEdit;
        Dragging := True;
        DragBtn := btn;
        DragX0 := cx;
        DragY0 := cy;
        LastX := cx;
        LastY := cy;
        if Tool = tlPencil then SetCell(cx, cy, ch);
      end;
    end;
    Exit;
  end;

  // dragging
  if DragBtn = MOUSE_BUTTON_RIGHT then ch := '.' else ch := TileChars[CurTile];
  cx := EnsureRange(cx, 0, MAP_W - 1);
  cy := EnsureRange(cy, 0, MAP_H - 1);
  if Tool = tlPencil then
  begin
    if (cx <> LastX) or (cy <> LastY) then
    begin
      PaintLine(LastX, LastY, cx, cy, ch);
      LastX := cx;
      LastY := cy;
    end;
  end;
  if IsMouseButtonReleased(DragBtn) then
  begin
    if Tool in [tlRoom, tlArea] then
      FillRectCells(DragX0, DragY0, cx, cy, ch, Tool = tlRoom);
    Dragging := False;
    EndEdit;
  end;
end;

{ ================================================================ main }

procedure AutoTestStep(frame: Integer);
begin
  // scripted edit: carve a small room with a door into the map, then screenshot and quit
  case frame of
    5:
      begin
        BeginEdit;
        FillRectCells(9, 18, 16, 22, '%', True);
        SetCell(12, 18, 'D');
        SetCell(13, 20, 'd');
        EndEdit;
        CurTile := 2;
        Tool := tlRoom;
      end;
    20: TakeScreenshot('editor_autotest.png');
    21:
      begin
        FileName := 'autotest.map';
        SaveMap;
        Quit := True;
      end;
  end;
end;

procedure RunEditor;
var
  i, frame: Integer;
  mp: TVector2;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  AutoTest := False;
  FileName := DEFAULT_MAP_FILE;
  for i := 1 to ParamCount do
    if ParamStr(i) = '--autotest' then AutoTest := True else FileName := ParamStr(i);

  // start from the file if it exists, otherwise from the game's built-in level
  if not LoadMapFile(MapPath(FileName), Grid) then
  begin
    DefaultGrid(Grid);
    Say('Started from the built-in level. Save to create ' + FileName);
  end
  else
    Say('Opened ' + MapPath(FileName));
  ShowGrid := True;

  SetTraceLogLevel(LOG_WARNING);
  SetConfigFlags(FLAG_VSYNC_HINT);
  InitWindow(WIN_W, WIN_H, 'RayDoom Map Editor');
  SetExitKey(KEY_NULL);
  SetTargetFPS(60);

  LoadCharConfig(ExePath(CHAR_CONFIG_FILE));   // monster thumbnails match the character editor
  GenerateTextures;
  for i := 0 to NUM_TEX - 1 do WallT[i] := TexFromPixels(WallTex[i]);
  for i := 0 to NUM_SPR - 1 do SprT[i] := TexFromPixels(SprTex[i]);

  frame := 0;
  while not Quit do
  begin
    Inc(frame);
    if WindowShouldClose then RequestAction(paQuit);
    mp := GetMousePosition;
    MouseX := Round(mp.x);
    MouseY := Round(mp.y);
    MsgTimer := MsgTimer - GetFrameTime;
    if AutoTest then AutoTestStep(frame);

    HandleKeys;
    HandleGridMouse;
    AnalyzeMap;
    UpdateTitle;

    BeginDrawing;
    ClearBackground(C(30, 30, 33));
    DrawGrid;
    DrawPanel;
    DrawTopBar;
    DrawStatus;
    if Pending <> paNone then DrawConfirm;
    EndDrawing;
  end;

  for i := 0 to NUM_TEX - 1 do UnloadTexture(WallT[i]);
  for i := 0 to NUM_SPR - 1 do UnloadTexture(SprT[i]);
  CloseWindow;
end;

end.
