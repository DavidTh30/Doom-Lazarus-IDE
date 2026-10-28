unit doomgame;

{ RayDoom: a Doom-style first person shooter.
  The 3D view is software rendered (textured walls, floors, ceilings, sprites, fog)
  into a 320x168 pixel buffer, uploaded to a raylib texture each frame and scaled 4x.
  raylib handles the window, input, audio, the weapon overlay and the HUD. }

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

procedure RunGame;

implementation

uses
  SysUtils, Math, raylib, doomparams, doomassets, doomsound, doomchars, doommap;

const
  WIN_W = 1280;
  WIN_H = 800;
  SCR_W = 320;                 // software framebuffer width
  VIEW_H = 168;                // software framebuffer height (3D view)
  PIX = 4;                     // window pixels per framebuffer pixel
  BAR_Y = VIEW_H * PIX;        // top of the status bar in window coordinates
  BAR_H = WIN_H - BAR_Y;
  HORIZON = VIEW_H / 2;
  FOV_PLANE = 0.66;
  MAX_ENTS = 256;
  PLAYER_R = 0.25;
  MONSTER_R = 0.3;


type
  TEntKind = (ekImp, ekDemon, ekMedkit, ekAmmo, ekLamp, ekFireball, ekPuff, ekBlood);
  TEntState = (esIdle, esChase, esAttack, esPain, esDead);
  TGameMode = (gmTitle, gmPlay, gmPaused, gmDead, gmWon);

  TEntity = record
    Active: Boolean;
    Kind: TEntKind;
    State: TEntState;
    X, Y, VX, VY: Single;
    HP: Integer;
    Timer, Anim, Cooldown: Single;
    Fired: Boolean;
  end;

var
  LevelGrid: TMapGrid;                                    // the map as loaded (with objects)
  LevelName: string;
  Map: array[0..MAP_W - 1, 0..MAP_H - 1] of Char;         // walls/doors only
  DoorOpen: array[0..MAP_W - 1, 0..MAP_H - 1] of Single;   // 0 = closed, 1 = fully open
  DoorState: array[0..MAP_W - 1, 0..MAP_H - 1] of Byte;    // 0 closed, 1 opening, 2 open, 3 closing
  DoorTimer: array[0..MAP_W - 1, 0..MAP_H - 1] of Single;
  DoorHoriz: array[0..MAP_W - 1, 0..MAP_H - 1] of Boolean; // door plane runs along X
  Ents: array[0..MAX_ENTS - 1] of TEntity;

  PX, PY, PAngle, DirX, DirY, PlaneX, PlaneY, CamH: Single;
  Health, Ammo, Kills, TotalKills: Integer;
  FireCD, FlashT, Recoil, BobPhase, BobAmt, DamageFlash, BonusFlash: Single;
  MsgText: string;
  MsgTimer, GrinT, PainFaceT, DeathT, LevelTime: Single;
  Mode: TGameMode;
  ShowMap, SkipMouse, QuitRequested, AutoTest: Boolean;

  FrameBuf: array[0..SCR_W * VIEW_H - 1] of Cardinal;
  ZBuf: array[0..SCR_W - 1] of Single;
  ScreenTex: TTexture2D;
  ViewRT: TRenderTexture2D;
  Proj: Single;

{ ================================================================ helpers }

function C(r, g, b: Integer; a: Integer = 255): TColor; inline;
begin
  Result := ColorRGBA(r, g, b, a);
end;

function ShadeC(c: Cardinal; s: Integer): Cardinal; inline;
begin
  Result := (((c and $FF) * Cardinal(s)) shr 8) or
            (((((c shr 8) and $FF) * Cardinal(s)) shr 8) shl 8) or
            (((((c shr 16) and $FF) * Cardinal(s)) shr 8) shl 16) or $FF000000;
end;

// Distance fog: 256 = full brightness
function FogShade(d: Single): Integer; inline;
var
  v: Single;
begin
  v := 1.12 - d * 0.085;
  if v > 1 then v := 1;
  if v < 0.1 then v := 0.1;
  Result := Round(v * 256);
end;

procedure ShowMessage(const s: string);
begin
  MsgText := s;
  MsgTimer := 3;
end;

function CellAt(x, y: Integer): Char; inline;
begin
  if (x < 0) or (y < 0) or (x >= MAP_W) or (y >= MAP_H) then
    Result := '#'
  else
    Result := Map[x, y];
end;

function IsWallCh(ch: Char): Boolean; inline;
begin
  Result := ch in ['#', '%', '&', '=', 'X'];
end;

function Solid(x, y: Integer): Boolean;
var
  ch: Char;
begin
  ch := CellAt(x, y);
  if ch = 'D' then
    Result := DoorOpen[x, y] < 0.9
  else
    Result := IsWallCh(ch);
end;

function TexIndex(ch: Char): Integer;
begin
  case ch of
    '%': Result := TEX_STONE;
    '&': Result := TEX_TECH;
    '=': Result := TEX_WOOD;
    'X': Result := TEX_EXIT;
  else
    Result := TEX_BRICK;
  end;
end;

function BlockedAt(x, y, r: Single): Boolean;
begin
  Result := Solid(Floor(x - r), Floor(y - r)) or Solid(Floor(x + r), Floor(y - r)) or
            Solid(Floor(x - r), Floor(y + r)) or Solid(Floor(x + r), Floor(y + r));
end;

function LineOfSight(x0, y0, x1, y1: Single): Boolean;
var
  d, sx, sy: Single;
  n, k: Integer;
begin
  d := Sqrt(Sqr(x1 - x0) + Sqr(y1 - y0));
  n := Ceil(d / 0.1);
  Result := True;
  if n < 2 then Exit;
  sx := (x1 - x0) / n;
  sy := (y1 - y0) / n;
  for k := 1 to n - 1 do
    if Solid(Floor(x0 + sx * k), Floor(y0 + sy * k)) then
      Exit(False);
end;

function DistToPlayer(const e: TEntity): Single; inline;
begin
  Result := Sqrt(Sqr(e.X - PX) + Sqr(e.Y - PY));
end;

function IsLiveMonster(const e: TEntity): Boolean; inline;
begin
  Result := e.Active and (e.Kind in [ekImp, ekDemon]) and (e.State <> esDead);
end;

// A monster's stat from its character definition (characters.cfg)
function MStat(const e: TEntity; param: Integer): Single; inline;
begin
  if e.Kind = ekDemon then
    Result := MonDefs[MON_DEMON][param]
  else
    Result := MonDefs[MON_IMP][param];
end;

function RandDmg(lo, hi: Single): Integer;
begin
  Result := Round(lo) + Random(Max(0, Round(hi) - Round(lo)) + 1);
end;

function MaxAmmo: Integer; inline;
begin
  Result := Round(PlayerDef[PP_MAXAMMO]);
end;

function MaxHealth: Integer; inline;
begin
  Result := Round(PlayerDef[PP_MAXHEALTH]);
end;

function FireDelay: Single; inline;
begin
  Result := PlayerDef[PP_FIRECD];
end;

procedure PlaySfxAt(const s: TSound; x, y: Single);
var
  vol: Single;
begin
  vol := 1 - Sqrt(Sqr(x - PX) + Sqr(y - PY)) / 22;
  if vol > 0.05 then
    PlaySfx(s, vol, 0.9 + Random * 0.2);
end;

procedure UpdateDirs;
begin
  DirX := Cos(PAngle);
  DirY := Sin(PAngle);
  PlaneX := -DirY * FOV_PLANE;
  PlaneY := DirX * FOV_PLANE;
end;

function SpawnEntity(kind: TEntKind; x, y: Single): Integer;
var
  i: Integer;
begin
  for i := 0 to MAX_ENTS - 1 do
    if not Ents[i].Active then
    begin
      FillChar(Ents[i], SizeOf(TEntity), 0);
      Ents[i].Active := True;
      Ents[i].Kind := kind;
      Ents[i].X := x;
      Ents[i].Y := y;
      case kind of
        ekImp: Ents[i].HP := Round(MonDefs[MON_IMP][MP_HP]);
        ekDemon: Ents[i].HP := Round(MonDefs[MON_DEMON][MP_HP]);
      end;
      Exit(i);
    end;
  Result := -1;
end;

{ ================================================================ level }

procedure LoadLevel;
var
  x, y: Integer;
  ch: Char;
  hasStart: Boolean;
begin
  FillChar(Ents, SizeOf(Ents), 0);
  FillChar(DoorOpen, SizeOf(DoorOpen), 0);
  FillChar(DoorState, SizeOf(DoorState), 0);
  FillChar(DoorTimer, SizeOf(DoorTimer), 0);
  PX := 1.5;
  PY := 1.5;
  PAngle := 0;
  TotalKills := 0;
  hasStart := False;

  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
    begin
      ch := LevelGrid[x, y];
      Map[x, y] := '.';
      case ch of
        '#', '%', '&', '=', 'X', 'D': Map[x, y] := ch;
        'P': begin PX := x + 0.5; PY := y + 0.5; hasStart := True; end;
        'i': if SpawnEntity(ekImp, x + 0.5, y + 0.5) >= 0 then Inc(TotalKills);
        'd': if SpawnEntity(ekDemon, x + 0.5, y + 0.5) >= 0 then Inc(TotalKills);
        'h': SpawnEntity(ekMedkit, x + 0.5, y + 0.5);
        'a': SpawnEntity(ekAmmo, x + 0.5, y + 0.5);
        'l': SpawnEntity(ekLamp, x + 0.5, y + 0.5);
      end;
    end;

  // maps without a player start: begin on the first free floor cell
  if not hasStart then
    for y := 0 to MAP_H - 1 do
      for x := 0 to MAP_W - 1 do
        if (not hasStart) and (LevelGrid[x, y] = '.') then
        begin
          PX := x + 0.5;
          PY := y + 0.5;
          hasStart := True;
        end;

  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
      DoorHoriz[x, y] := IsWallCh(CellAt(x - 1, y)) and IsWallCh(CellAt(x + 1, y));

  Health := Round(PlayerDef[PP_HEALTH]);
  Ammo := Round(PlayerDef[PP_AMMO]);
  Kills := 0;
  FireCD := 0;
  FlashT := 0;
  Recoil := 0;
  BobPhase := 0;
  BobAmt := 0;
  DamageFlash := 0;
  BonusFlash := 0;
  GrinT := 0;
  PainFaceT := 0;
  DeathT := 0;
  LevelTime := 0;
  CamH := 0.5;
  MsgTimer := 0;
  UpdateDirs;
end;

{ ================================================================ rendering }

procedure RenderFloorCeil;
var
  x, y, s: Integer;
  p, rowDist, rdx0, rdy0, rdx1, rdy1, fx, fy, stx, sty: Single;
  tp: PTexPixels;
  dst: PCardinal;
begin
  rdx0 := DirX - PlaneX;
  rdy0 := DirY - PlaneY;
  rdx1 := DirX + PlaneX;
  rdy1 := DirY + PlaneY;
  for y := 0 to VIEW_H - 1 do
  begin
    if y + 0.5 >= HORIZON then
    begin
      p := y + 0.5 - HORIZON;
      rowDist := CamH * Proj / p;
      tp := @WallTex[TEX_FLOOR];
    end
    else
    begin
      p := HORIZON - (y + 0.5);
      rowDist := (1 - CamH) * Proj / p;
      tp := @WallTex[TEX_CEIL];
    end;
    stx := rowDist * (rdx1 - rdx0) / SCR_W;
    sty := rowDist * (rdy1 - rdy0) / SCR_W;
    fx := PX + rowDist * rdx0;
    fy := PY + rowDist * rdy0;
    s := FogShade(rowDist);
    dst := @FrameBuf[y * SCR_W];
    for x := 0 to SCR_W - 1 do
    begin
      dst^ := ShadeC(tp^[(Trunc(fx * TEX_SIZE) and (TEX_SIZE - 1)) +
                         (Trunc(fy * TEX_SIZE) and (TEX_SIZE - 1)) * TEX_SIZE], s);
      Inc(dst);
      fx := fx + stx;
      fy := fy + sty;
    end;
  end;
end;

procedure RenderWalls;
var
  x, y, mapX, mapY, stepX, stepY, side, tex, texX, y0, y1, s, i, prevX, prevY: Integer;
  camX, rdx, rdy, sdx, sdy, ddx, ddy, perp, u, t, h, lineH, top, texPos, texStep: Single;
  ch: Char;
  tp: PTexPixels;
begin
  for x := 0 to SCR_W - 1 do
  begin
    camX := 2 * x / SCR_W - 1;
    rdx := DirX + PlaneX * camX;
    rdy := DirY + PlaneY * camX;
    mapX := Floor(PX);
    mapY := Floor(PY);
    if rdx = 0 then ddx := 1e30 else ddx := Abs(1 / rdx);
    if rdy = 0 then ddy := 1e30 else ddy := Abs(1 / rdy);
    if rdx < 0 then
    begin
      stepX := -1;
      sdx := (PX - mapX) * ddx;
    end
    else
    begin
      stepX := 1;
      sdx := (mapX + 1 - PX) * ddx;
    end;
    if rdy < 0 then
    begin
      stepY := -1;
      sdy := (PY - mapY) * ddy;
    end
    else
    begin
      stepY := 1;
      sdy := (mapY + 1 - PY) * ddy;
    end;

    perp := 64;
    tex := TEX_BRICK;
    u := 0;
    side := 0;
    for i := 0 to 255 do
    begin
      prevX := mapX;
      prevY := mapY;
      if sdx < sdy then
      begin
        sdx := sdx + ddx;
        Inc(mapX, stepX);
        side := 0;
      end
      else
      begin
        sdy := sdy + ddy;
        Inc(mapY, stepY);
        side := 1;
      end;
      ch := CellAt(mapX, mapY);
      if ch = 'D' then
      begin
        // Doors are thin planes through the middle of their cell and slide sideways
        if DoorHoriz[mapX, mapY] then
        begin
          if rdy <> 0 then
          begin
            t := (mapY + 0.5 - PY) / rdy;
            h := PX + t * rdx - mapX;
            if (t > 0) and (h >= DoorOpen[mapX, mapY]) and (h < 1) then
            begin
              perp := t;
              u := h - DoorOpen[mapX, mapY];
              tex := TEX_DOOR;
              side := 1;
              Break;
            end;
          end;
        end
        else if rdx <> 0 then
        begin
          t := (mapX + 0.5 - PX) / rdx;
          h := PY + t * rdy - mapY;
          if (t > 0) and (h >= DoorOpen[mapX, mapY]) and (h < 1) then
          begin
            perp := t;
            u := h - DoorOpen[mapX, mapY];
            tex := TEX_DOOR;
            side := 0;
            Break;
          end;
        end;
      end
      else if IsWallCh(ch) then
      begin
        if side = 0 then perp := sdx - ddx else perp := sdy - ddy;
        if side = 0 then u := PY + perp * rdy else u := PX + perp * rdx;
        u := u - Floor(u);
        if (side = 0) and (rdx > 0) then u := 1 - u;
        if (side = 1) and (rdy < 0) then u := 1 - u;
        tex := TexIndex(ch);
        // walls seen from inside a door frame get the metal door-track texture
        if CellAt(prevX, prevY) = 'D' then tex := TEX_TECH;
        Break;
      end;
    end;

    if perp < 0.05 then perp := 0.05;
    ZBuf[x] := perp;
    lineH := Proj / perp;
    top := HORIZON - (1 - CamH) * lineH;
    y0 := Max(0, Ceil(top));
    y1 := Min(VIEW_H - 1, Ceil(top + lineH) - 1);
    texX := Trunc(u * TEX_SIZE) and (TEX_SIZE - 1);
    s := FogShade(perp);
    if side = 1 then s := s * 205 div 256;      // Doom-style fake contrast
    if tex = TEX_EXIT then s := Max(s, 230);     // the exit switch glows
    texStep := TEX_SIZE / lineH;
    texPos := (y0 - top) * texStep;
    tp := @WallTex[tex];
    for y := y0 to y1 do
    begin
      FrameBuf[y * SCR_W + x] := ShadeC(tp^[texX + (Trunc(texPos) and (TEX_SIZE - 1)) * TEX_SIZE], s);
      texPos := texPos + texStep;
    end;
  end;
end;

procedure SpriteInfo(const e: TEntity; out spr: Integer; out scale, z: Single; out bright: Boolean);
begin
  bright := False;
  z := 0;
  scale := 0.95;
  spr := SPR_PUFF;
  case e.Kind of
    ekImp, ekDemon:
      begin
        if e.Kind = ekImp then spr := SPR_IMP else spr := SPR_DEMON;
        case e.State of
          esDead: Inc(spr, FR_DEAD);
          esPain: Inc(spr, FR_PAIN);
          esAttack: Inc(spr, FR_ATTACK);
          esChase: if Frac(e.Anim * 3) < 0.5 then Inc(spr, FR_WALK2);
        end;
        scale := MStat(e, MP_SCALE);
      end;
    ekMedkit: begin spr := SPR_MEDKIT; scale := 0.5; end;
    ekAmmo: begin spr := SPR_AMMO; scale := 0.5; end;
    ekLamp: begin spr := SPR_LAMP; scale := 1.0; end;
    ekFireball:
      begin
        if Frac(e.Anim * 8) < 0.5 then spr := SPR_FIRE1 else spr := SPR_FIRE2;
        scale := 0.4;
        z := 0.3;
        bright := True;
      end;
    ekPuff: begin spr := SPR_PUFF; scale := 0.3; z := 0.35 + e.Anim * 0.4; end;
    ekBlood: begin spr := SPR_BLOOD; scale := 0.3; z := 0.35 - e.Anim * 0.5; end;
  end;
end;

procedure RenderSprites;
var
  order: array[0..MAX_ENTS - 1] of Integer;
  dist: array[0..MAX_ENTS - 1] of Single;
  n, i, j, k, spr, x, y, x0, x1, y0, y1, s, tx, ty: Integer;
  invDet, sx, sy, tX_, tY_, scrX, size, bottom, top, left, scale, z, d: Single;
  bright: Boolean;
  tp: PTexPixels;
  col: Cardinal;
begin
  n := 0;
  for i := 0 to MAX_ENTS - 1 do
    if Ents[i].Active then
    begin
      d := Sqr(Ents[i].X - PX) + Sqr(Ents[i].Y - PY);
      // insertion sort, far to near
      j := n;
      while (j > 0) and (dist[j - 1] < d) do
      begin
        order[j] := order[j - 1];
        dist[j] := dist[j - 1];
        Dec(j);
      end;
      order[j] := i;
      dist[j] := d;
      Inc(n);
    end;

  invDet := 1 / (PlaneX * DirY - DirX * PlaneY);
  for k := 0 to n - 1 do
  begin
    SpriteInfo(Ents[order[k]], spr, scale, z, bright);
    sx := Ents[order[k]].X - PX;
    sy := Ents[order[k]].Y - PY;
    tX_ := invDet * (DirY * sx - DirX * sy);
    tY_ := invDet * (-PlaneY * sx + PlaneX * sy);
    if tY_ <= 0.1 then Continue;
    scrX := (SCR_W / 2) * (1 + tX_ / tY_);
    size := scale * Proj / tY_;
    bottom := HORIZON + (CamH - z) * Proj / tY_;
    top := bottom - size;
    left := scrX - size / 2;
    x0 := Max(0, Ceil(left));
    x1 := Min(SCR_W - 1, Ceil(left + size) - 1);
    y0 := Max(0, Ceil(top));
    y1 := Min(VIEW_H - 1, Ceil(bottom) - 1);
    if bright then s := 256 else s := FogShade(tY_);
    tp := @SprTex[spr];
    for x := x0 to x1 do
    begin
      if tY_ >= ZBuf[x] then Continue;
      tx := EnsureRange(Trunc((x - left) * TEX_SIZE / size), 0, TEX_SIZE - 1);
      for y := y0 to y1 do
      begin
        ty := EnsureRange(Trunc((y - top) * TEX_SIZE / size), 0, TEX_SIZE - 1);
        col := tp^[tx + ty * TEX_SIZE];
        if (col shr 24) <> 0 then
          FrameBuf[y * SCR_W + x] := ShadeC(col, s);
      end;
    end;
  end;
end;

procedure RenderScene;
begin
  RenderFloorCeil;
  RenderWalls;
  RenderSprites;
end;

{ ================================================================ combat }

procedure DamagePlayer(amount: Integer);
begin
  if Mode <> gmPlay then Exit;
  Dec(Health, amount);
  DamageFlash := Min(0.75, DamageFlash + 0.15 + amount * 0.02);
  PainFaceT := 0.6;
  if Health <= 0 then
  begin
    Health := 0;
    Mode := gmDead;
    DeathT := 0;
    PlaySfx(Sfx[SFX_PLAYERDEATH]);
  end
  else
    PlaySfx(Sfx[SFX_PLAYERPAIN], 1, 0.9 + Random * 0.2);
end;

procedure WakeMonster(i: Integer);
begin
  if Ents[i].State <> esIdle then Exit;
  Ents[i].State := esChase;
  Ents[i].Cooldown := 0.8 + Random;
  if Ents[i].Kind = ekImp then
    PlaySfxAt(Sfx[SFX_IMPSIGHT], Ents[i].X, Ents[i].Y)
  else
    PlaySfxAt(Sfx[SFX_DEMONSIGHT], Ents[i].X, Ents[i].Y);
end;

procedure DamageMonster(i, amount: Integer);
var
  painChance: Single;
begin
  if not IsLiveMonster(Ents[i]) then Exit;
  Dec(Ents[i].HP, amount);
  if Ents[i].HP <= 0 then
  begin
    Ents[i].State := esDead;
    Inc(Kills);
    GrinT := 1.2;
    PlaySfxAt(Sfx[SFX_MONDEATH], Ents[i].X, Ents[i].Y);
    if Random < MStat(Ents[i], MP_DROP) then
      SpawnEntity(ekAmmo, Ents[i].X + 0.2, Ents[i].Y + 0.2);
    Exit;
  end;
  WakeMonster(i);
  painChance := MStat(Ents[i], MP_PAIN);
  if (Ents[i].State <> esAttack) and (Ents[i].State <> esPain) and (Random < painChance) then
  begin
    Ents[i].State := esPain;
    Ents[i].Timer := 0.25;
    PlaySfxAt(Sfx[SFX_MONPAIN], Ents[i].X, Ents[i].Y);
  end;
end;

// Distance along a ray to the first solid cell (closed doors count as solid)
function RayWallDist(rx, ry: Single): Single;
var
  d: Single;
begin
  d := 0;
  while d < 40 do
  begin
    d := d + 0.02;
    if Solid(Floor(PX + rx * d), Floor(PY + ry * d)) then Break;
  end;
  Result := d;
end;

procedure FirePellet(ang: Single);
var
  rx, ry, wallD, bestD, ex, ey, along, lat: Single;
  i, best: Integer;
begin
  rx := Cos(ang);
  ry := Sin(ang);
  wallD := RayWallDist(rx, ry);
  best := -1;
  bestD := wallD;
  for i := 0 to MAX_ENTS - 1 do
    if IsLiveMonster(Ents[i]) then
    begin
      ex := Ents[i].X - PX;
      ey := Ents[i].Y - PY;
      along := ex * rx + ey * ry;
      if (along > 0) and (along < bestD) then
      begin
        lat := Abs(ex * ry - ey * rx);
        if lat < 0.32 then
        begin
          best := i;
          bestD := along;
        end;
      end;
    end;
  if best >= 0 then
  begin
    DamageMonster(best, RandDmg(PlayerDef[PP_PDMGMIN], PlayerDef[PP_PDMGMAX]));
    SpawnEntity(ekBlood, PX + rx * (bestD - 0.15), PY + ry * (bestD - 0.15));
  end
  else
    SpawnEntity(ekPuff, PX + rx * (wallD - 0.05), PY + ry * (wallD - 0.05));
end;

procedure FireShotgun;
var
  i: Integer;
  d: Single;
begin
  if Ammo <= 0 then
  begin
    ShowMessage('You need more shells!');
    FireCD := 0.5;
    Exit;
  end;
  Dec(Ammo);
  FireCD := FireDelay;
  FlashT := 0.1;
  Recoil := 1;
  PlaySfx(Sfx[SFX_SHOTGUN], 1, 0.95 + Random * 0.1);
  // the blast wakes monsters that can hear it
  for i := 0 to MAX_ENTS - 1 do
    if IsLiveMonster(Ents[i]) and (Ents[i].State = esIdle) then
    begin
      d := DistToPlayer(Ents[i]);
      if (d < 6) or ((d < 16) and LineOfSight(Ents[i].X, Ents[i].Y, PX, PY)) then
        WakeMonster(i);
    end;
  for i := 1 to Round(PlayerDef[PP_PELLETS]) do
    FirePellet(PAngle + (Random - 0.5) * PlayerDef[PP_SPREAD]);
end;

{ ================================================================ doors }

function CellOccupied(cx, cy: Integer): Boolean;
var
  i: Integer;
begin
  Result := (PX + PLAYER_R > cx) and (PX - PLAYER_R < cx + 1) and
            (PY + PLAYER_R > cy) and (PY - PLAYER_R < cy + 1);
  if Result then Exit;
  for i := 0 to MAX_ENTS - 1 do
    if IsLiveMonster(Ents[i]) and (Ents[i].X + MONSTER_R > cx) and (Ents[i].X - MONSTER_R < cx + 1) and
       (Ents[i].Y + MONSTER_R > cy) and (Ents[i].Y - MONSTER_R < cy + 1) then
      Exit(True);
end;

procedure OpenDoor(cx, cy: Integer);
begin
  if CellAt(cx, cy) <> 'D' then Exit;
  if DoorState[cx, cy] in [0, 3] then
  begin
    DoorState[cx, cy] := 1;
    PlaySfxAt(Sfx[SFX_DOOR], cx + 0.5, cy + 0.5);
  end;
end;

procedure UpdateDoors(dt: Single);
var
  x, y: Integer;
begin
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
      if Map[x, y] = 'D' then
        case DoorState[x, y] of
          1:
            begin
              DoorOpen[x, y] := DoorOpen[x, y] + dt * 1.6;
              if DoorOpen[x, y] >= 1 then
              begin
                DoorOpen[x, y] := 1;
                DoorState[x, y] := 2;
                DoorTimer[x, y] := 4;
              end;
            end;
          2:
            begin
              DoorTimer[x, y] := DoorTimer[x, y] - dt;
              if DoorTimer[x, y] <= 0 then
              begin
                if CellOccupied(x, y) then
                  DoorTimer[x, y] := 1
                else
                begin
                  DoorState[x, y] := 3;
                  PlaySfxAt(Sfx[SFX_DOOR], x + 0.5, y + 0.5);
                end;
              end;
            end;
          3:
            if CellOccupied(x, y) then
              DoorState[x, y] := 1
            else
            begin
              DoorOpen[x, y] := DoorOpen[x, y] - dt * 1.6;
              if DoorOpen[x, y] <= 0 then
              begin
                DoorOpen[x, y] := 0;
                DoorState[x, y] := 0;
              end;
            end;
        end;
end;

{ ================================================================ player }

function MonsterBlocksPlayer(nx, ny: Single): Boolean;
var
  i: Integer;
  d0, d1: Single;
begin
  for i := 0 to MAX_ENTS - 1 do
    if IsLiveMonster(Ents[i]) then
    begin
      d1 := Sqr(nx - Ents[i].X) + Sqr(ny - Ents[i].Y);
      if d1 < Sqr(PLAYER_R + MONSTER_R) then
      begin
        d0 := Sqr(PX - Ents[i].X) + Sqr(PY - Ents[i].Y);
        if d1 < d0 then Exit(True);
      end;
    end;
  Result := False;
end;

procedure MovePlayer(mx, my: Single);
var
  nx, ny: Single;
begin
  nx := PX + mx;
  if not BlockedAt(nx, PY, PLAYER_R) and not MonsterBlocksPlayer(nx, PY) then PX := nx;
  ny := PY + my;
  if not BlockedAt(PX, ny, PLAYER_R) and not MonsterBlocksPlayer(PX, ny) then PY := ny;
end;

procedure UseAction;
const
  Reach: array[0..2] of Single = (0.6, 1.0, 1.4);
var
  k, cx, cy: Integer;
  ch: Char;
begin
  for k := 0 to High(Reach) do
  begin
    cx := Floor(PX + DirX * Reach[k]);
    cy := Floor(PY + DirY * Reach[k]);
    ch := CellAt(cx, cy);
    if ch = 'D' then
    begin
      OpenDoor(cx, cy);
      Exit;
    end
    else if ch = 'X' then
    begin
      PlaySfx(Sfx[SFX_SWITCH]);
      Mode := gmWon;
      EnableCursor;
      Exit;
    end
    else if ch <> '.' then
      Exit;
  end;
end;

procedure PickupItems;
var
  i: Integer;
begin
  for i := 0 to MAX_ENTS - 1 do
    if Ents[i].Active and (Ents[i].Kind in [ekMedkit, ekAmmo]) and (DistToPlayer(Ents[i]) < 0.55) then
    begin
      if Ents[i].Kind = ekMedkit then
      begin
        if Health >= MaxHealth then Continue;
        Health := Min(MaxHealth, Health + Round(PlayerDef[PP_MEDKIT]));
        ShowMessage('Picked up a medikit.');
      end
      else
      begin
        if Ammo >= MaxAmmo then Continue;
        Ammo := Min(MaxAmmo, Ammo + Round(PlayerDef[PP_AMMOBOX]));
        ShowMessage('Picked up a box of shotgun shells.');
      end;
      Ents[i].Active := False;
      BonusFlash := 0.5;
      PlaySfx(Sfx[SFX_PICKUP]);
    end;
end;

procedure UpdatePlayer(dt: Single);
var
  md: TVector2;
  fwd, str, spd, len: Single;
  running: Boolean;
begin
  md := GetMouseDelta;
  if SkipMouse then
    SkipMouse := False
  else
    PAngle := PAngle + md.x * PlayerDef[PP_MOUSE];
  if IsKeyDown(KEY_LEFT) then PAngle := PAngle - 2.6 * dt;
  if IsKeyDown(KEY_RIGHT) then PAngle := PAngle + 2.6 * dt;
  UpdateDirs;

  fwd := 0;
  str := 0;
  if IsKeyDown(KEY_W) or IsKeyDown(KEY_UP) then fwd := fwd + 1;
  if IsKeyDown(KEY_S) or IsKeyDown(KEY_DOWN) then fwd := fwd - 1;
  if IsKeyDown(KEY_D) then str := str + 1;
  if IsKeyDown(KEY_A) then str := str - 1;
  running := IsKeyDown(KEY_LEFT_SHIFT);
  spd := PlayerDef[PP_SPEED];
  if running then spd := spd * PlayerDef[PP_RUN];
  len := Sqrt(fwd * fwd + str * str);
  if len > 0 then
  begin
    fwd := fwd / len;
    str := str / len;
    MovePlayer((DirX * fwd - DirY * str) * spd * dt, (DirY * fwd + DirX * str) * spd * dt);
    BobPhase := BobPhase + dt * spd * 3.2;
    BobAmt := Min(1, BobAmt + dt * 4);
  end
  else
    BobAmt := Max(0, BobAmt - dt * 4);
  CamH := 0.5 + Sin(BobPhase) * 0.012 * BobAmt;

  if IsKeyPressed(KEY_E) or IsKeyPressed(KEY_SPACE) then UseAction;
  if IsKeyPressed(KEY_TAB) or IsKeyPressed(KEY_M) then ShowMap := not ShowMap;

  FireCD := FireCD - dt;
  if (IsMouseButtonDown(MOUSE_BUTTON_LEFT) or IsKeyDown(KEY_LEFT_CONTROL) or IsKeyDown(KEY_RIGHT_CONTROL)) and
     (FireCD <= 0) and (Mode = gmPlay) then
    FireShotgun;

  PickupItems;
end;

{ ================================================================ monsters & projectiles }

function MonsterBlocked(i: Integer; nx, ny: Single): Boolean;
var
  j: Integer;
  d0, d1: Single;
begin
  Result := True;
  if BlockedAt(nx, ny, MONSTER_R) then Exit;
  if (Mode in [gmPlay, gmPaused]) and (Sqr(nx - PX) + Sqr(ny - PY) < Sqr(PLAYER_R + MONSTER_R)) then Exit;
  for j := 0 to MAX_ENTS - 1 do
    if (j <> i) and IsLiveMonster(Ents[j]) then
    begin
      d1 := Sqr(nx - Ents[j].X) + Sqr(ny - Ents[j].Y);
      if d1 < Sqr(2 * MONSTER_R) then
      begin
        d0 := Sqr(Ents[i].X - Ents[j].X) + Sqr(Ents[i].Y - Ents[j].Y);
        if d1 < d0 then Exit;
      end;
    end;
  Result := False;
end;

function MonsterMove(i: Integer; mx, my: Single): Boolean;
var
  nx, ny: Single;
begin
  Result := False;
  nx := Ents[i].X + mx;
  if not MonsterBlocked(i, nx, Ents[i].Y) then
  begin
    Ents[i].X := nx;
    Result := True;
  end
  else
    OpenDoor(Floor(nx + Sign(mx) * MONSTER_R), Floor(Ents[i].Y));
  ny := Ents[i].Y + my;
  if not MonsterBlocked(i, Ents[i].X, ny) then
  begin
    Ents[i].Y := ny;
    Result := True;
  end
  else
    OpenDoor(Floor(Ents[i].X), Floor(ny + Sign(my) * MONSTER_R));
end;

procedure UpdateMonster(i: Integer; dt: Single);
var
  dx, dy, dist, spd, ang, mx, my: Single;
  fb: Integer;
  ranged, seen: Boolean;
begin
  ranged := MStat(Ents[i], MP_RANGED) >= 0.5;
  dx := PX - Ents[i].X;
  dy := PY - Ents[i].Y;
  dist := Sqrt(dx * dx + dy * dy);
  Ents[i].Anim := Ents[i].Anim + dt;
  Ents[i].Cooldown := Ents[i].Cooldown - dt;

  case Ents[i].State of
    esIdle:
      if (Mode = gmPlay) and (dist < MStat(Ents[i], MP_SIGHT)) and LineOfSight(Ents[i].X, Ents[i].Y, PX, PY) then
        WakeMonster(i);

    esChase:
      begin
        if Mode <> gmPlay then Exit;
        spd := MStat(Ents[i], MP_SPEED);
        if dist > 0.75 then
        begin
          // weave a little while advancing, like the originals do
          ang := ArcTan2(dy, dx) + Sin(Ents[i].Anim * 1.7 + i) * 0.6;
          mx := Cos(ang) * spd * dt;
          my := Sin(ang) * spd * dt;
          if not MonsterMove(i, mx, my) then
            MonsterMove(i, -my, mx);
        end;
        if ranged then
        begin
          if (Ents[i].Cooldown <= 0) and (dist < MStat(Ents[i], MP_RANGE)) and (Random < dt * 2) then
          begin
            seen := LineOfSight(Ents[i].X, Ents[i].Y, PX, PY);
            if seen then
            begin
              Ents[i].State := esAttack;
              Ents[i].Timer := 0.7;
              Ents[i].Fired := False;
            end;
          end;
        end
        else if (dist < MStat(Ents[i], MP_RANGE)) and (Ents[i].Cooldown <= 0) then
        begin
          Ents[i].State := esAttack;
          Ents[i].Timer := 0.45;
          Ents[i].Fired := False;
        end;
      end;

    esAttack:
      begin
        Ents[i].Timer := Ents[i].Timer - dt;
        if ranged then
        begin
          if (not Ents[i].Fired) and (Ents[i].Timer < 0.35) then
          begin
            Ents[i].Fired := True;
            if dist > 0.01 then
            begin
              fb := SpawnEntity(ekFireball, Ents[i].X + dx / dist * 0.35, Ents[i].Y + dy / dist * 0.35);
              if fb >= 0 then
              begin
                Ents[fb].VX := dx / dist * MStat(Ents[i], MP_PROJSPEED);
                Ents[fb].VY := dy / dist * MStat(Ents[i], MP_PROJSPEED);
                Ents[fb].HP := RandDmg(MStat(Ents[i], MP_DMGMIN), MStat(Ents[i], MP_DMGMAX));  // damage it carries
              end;
              PlaySfxAt(Sfx[SFX_FIREBALL], Ents[i].X, Ents[i].Y);
            end;
          end;
          if Ents[i].Timer <= 0 then
          begin
            Ents[i].State := esChase;
            Ents[i].Cooldown := MStat(Ents[i], MP_COOLDOWN) * (1 + Random);
          end;
        end
        else
        begin
          if (not Ents[i].Fired) and (Ents[i].Timer < 0.2) then
          begin
            Ents[i].Fired := True;
            PlaySfxAt(Sfx[SFX_BITE], Ents[i].X, Ents[i].Y);
            if dist < MStat(Ents[i], MP_RANGE) + 0.3 then
              DamagePlayer(RandDmg(MStat(Ents[i], MP_DMGMIN), MStat(Ents[i], MP_DMGMAX)));
          end;
          if Ents[i].Timer <= 0 then
          begin
            Ents[i].State := esChase;
            Ents[i].Cooldown := MStat(Ents[i], MP_COOLDOWN);
          end;
        end;
      end;

    esPain:
      begin
        Ents[i].Timer := Ents[i].Timer - dt;
        if Ents[i].Timer <= 0 then Ents[i].State := esChase;
      end;
  end;
end;

procedure UpdateEntities(dt: Single);
var
  i: Integer;
begin
  for i := 0 to MAX_ENTS - 1 do
  begin
    if not Ents[i].Active then Continue;
    case Ents[i].Kind of
      ekImp, ekDemon:
        if Ents[i].State <> esDead then UpdateMonster(i, dt);

      ekFireball:
        begin
          Ents[i].Anim := Ents[i].Anim + dt;
          Ents[i].X := Ents[i].X + Ents[i].VX * dt;
          Ents[i].Y := Ents[i].Y + Ents[i].VY * dt;
          if Solid(Floor(Ents[i].X), Floor(Ents[i].Y)) or (Ents[i].Anim > 6) then
          begin
            Ents[i].Active := False;
            SpawnEntity(ekPuff, Ents[i].X - Ents[i].VX * 0.02, Ents[i].Y - Ents[i].VY * 0.02);
            PlaySfxAt(Sfx[SFX_EXPLODE], Ents[i].X, Ents[i].Y);
          end
          else if (Mode = gmPlay) and (DistToPlayer(Ents[i]) < 0.4) then
          begin
            Ents[i].Active := False;
            PlaySfxAt(Sfx[SFX_EXPLODE], Ents[i].X, Ents[i].Y);
            DamagePlayer(Ents[i].HP);
          end;
        end;

      ekPuff, ekBlood:
        begin
          Ents[i].Anim := Ents[i].Anim + dt;
          if Ents[i].Anim > 0.35 then Ents[i].Active := False;
        end;
    end;
  end;
end;

{ ================================================================ 2D overlays }

procedure DrawTextShadow(const s: string; x, y, size: Integer; col: TColor);
begin
  DrawText(PChar(s), x + size div 12 + 1, y + size div 12 + 1, size, C(0, 0, 0, col.a));
  DrawText(PChar(s), x, y, size, col);
end;

procedure DrawTextCentered(const s: string; cx, y, size: Integer; col: TColor);
begin
  DrawTextShadow(s, cx - MeasureText(PChar(s), size) div 2, y, size, col);
end;

// The shotgun is drawn into the low-res view so it gets the same chunky pixels
procedure DrawWeapon;
var
  bx, by, pump, k: Integer;
  ph: Single;
  skin: TColor;
begin
  pump := 0;
  if FireCD > 0 then
  begin
    ph := 1 - FireCD / FireDelay;
    if (ph > 0.25) and (ph < 0.8) then
      pump := Round(Sin((ph - 0.25) / 0.55 * Pi) * 10);
  end;
  bx := 160 + Round(Cos(BobPhase * 0.5) * BobAmt * 6);
  by := VIEW_H + Round(Abs(Sin(BobPhase * 0.5)) * BobAmt * 4) + Round(Recoil * 8) + pump div 2;
  if Mode = gmDead then by := by + Round(Min(DeathT, 1) * 90);
  skin := C(200, 150, 110);

  // muzzle flash
  if FlashT > 0 then
  begin
    DrawCircle(bx, by - 86, 15, C(255, 160, 40, 230));
    DrawCircle(bx, by - 86, 8, C(255, 245, 190));
  end;
  // barrel and magazine tube
  DrawRectangle(bx - 7, by - 82, 14, 4, C(25, 25, 28));
  DrawRectangle(bx - 6, by - 78, 12, 62, C(42, 42, 46));
  DrawRectangle(bx - 4, by - 78, 3, 62, C(95, 95, 105));
  DrawRectangle(bx + 3, by - 78, 2, 62, C(28, 28, 30));
  // pump
  DrawRectangle(bx - 10, by - 54 + pump, 20, 22, C(110, 66, 32));
  for k := 0 to 3 do
    DrawRectangle(bx - 10, by - 50 + pump + k * 5, 20, 1, C(70, 40, 18));
  DrawRectangle(bx - 10, by - 54 + pump, 3, 22, C(145, 95, 50));
  // receiver
  DrawRectangle(bx - 13, by - 24, 26, 24, C(62, 62, 68));
  DrawRectangle(bx - 13, by - 24, 26, 2, C(105, 105, 115));
  // hands
  DrawCircle(bx - 12, by - 42 + pump, 7, skin);
  DrawCircle(bx + 12, by - 42 + pump, 7, skin);
  DrawCircle(bx - 12, by - 44 + pump, 3, C(225, 180, 140));
  DrawCircle(bx + 11, by - 3, 10, skin);
end;

procedure DrawFace(cx, cy: Integer);
var
  hurt: Single;
  skin: TColor;
  look, ey: Integer;
begin
  hurt := EnsureRange(1 - Health / MaxHealth, 0, 1);
  skin := C(Round(220 - hurt * 40), Round(170 - hurt * 70), Round(130 - hurt * 70));
  DrawEllipse(cx, cy + 6, 40, 50, skin);
  DrawRectangle(cx - 40, cy - 46, 80, 18, C(95, 60, 30));
  DrawEllipse(cx, cy - 34, 40, 14, C(95, 60, 30));
  ey := cy - 6;
  if Mode = gmDead then
  begin
    DrawLine(cx - 24, ey - 6, cx - 12, ey + 6, C(60, 0, 0));
    DrawLine(cx - 24, ey + 6, cx - 12, ey - 6, C(60, 0, 0));
    DrawLine(cx + 12, ey - 6, cx + 24, ey + 6, C(60, 0, 0));
    DrawLine(cx + 12, ey + 6, cx + 24, ey - 6, C(60, 0, 0));
    DrawEllipse(cx, cy + 26, 10, 7, C(90, 0, 0));
  end
  else
  begin
    if (FlashT > 0) or (GrinT > 0) then
      look := 0
    else
      look := (Trunc(GetTime / 1.5) mod 3 - 1) * 5;
    DrawEllipse(cx - 18, ey, 9, 7, C(240, 240, 240));
    DrawEllipse(cx + 18, ey, 9, 7, C(240, 240, 240));
    DrawCircle(cx - 18 + look, ey, 4, C(30, 60, 120));
    DrawCircle(cx + 18 + look, ey, 4, C(30, 60, 120));
    // brows
    if (FlashT > 0) or (FireCD > 0.5) then
    begin
      DrawRectangle(cx - 28, ey - 14, 20, 4, C(70, 40, 20));
      DrawRectangle(cx + 8, ey - 14, 20, 4, C(70, 40, 20));
    end;
    if GrinT > 0 then
    begin
      DrawRectangle(cx - 20, cy + 18, 40, 12, C(250, 250, 240));
      DrawRectangle(cx - 20, cy + 23, 40, 1, C(120, 120, 120));
    end
    else if PainFaceT > 0 then
      DrawEllipse(cx, cy + 26, 9, 10, C(70, 10, 10))
    else
      DrawRectangle(cx - 15, cy + 24, 30, 4, C(110, 50, 40));
  end;
  // blood
  if Health < 70 then DrawRectangle(cx - 30, cy - 22, 5, 30, C(170, 0, 0));
  if Health < 45 then DrawRectangle(cx + 26, cy - 10, 5, 38, C(170, 0, 0));
  if Health < 25 then DrawRectangle(cx - 6, cy - 28, 4, 22, C(170, 0, 0));
end;

procedure DrawPanel(x, w: Integer; const lbl, value: string);
var
  cx: Integer;
begin
  DrawRectangle(x + 6, BAR_Y + 10, w - 12, BAR_H - 20, C(48, 48, 50));
  DrawRectangle(x + 6, BAR_Y + 10, w - 12, 2, C(30, 30, 30));
  DrawRectangle(x + 6, BAR_Y + BAR_H - 12, w - 12, 2, C(100, 100, 100));
  cx := x + w div 2;
  if value <> '' then
  begin
    DrawText(PChar(value), cx - MeasureText(PChar(value), 64) div 2 + 4, BAR_Y + 18, 64, C(0, 0, 0));
    DrawText(PChar(value), cx - MeasureText(PChar(value), 64) div 2, BAR_Y + 14, 64, C(210, 30, 25));
  end;
  DrawText(PChar(lbl), cx - MeasureText(PChar(lbl), 20) div 2, BAR_Y + BAR_H - 38, 20, C(190, 190, 190));
end;

procedure DrawStatusBar;
var
  secs: Integer;
begin
  DrawRectangle(0, BAR_Y, WIN_W, BAR_H, C(72, 72, 74));
  DrawRectangle(0, BAR_Y, WIN_W, 4, C(120, 120, 122));
  DrawPanel(0, 230, 'AMMO', IntToStr(Ammo));
  DrawPanel(230, 300, 'HEALTH', IntToStr(Health) + '%');
  DrawRectangle(540, BAR_Y + 8, 200, BAR_H - 16, C(30, 30, 32));
  DrawFace(640, BAR_Y + BAR_H div 2);
  DrawPanel(750, 260, 'KILLS', Format('%d/%d', [Kills, TotalKills]));
  DrawPanel(1010, 270, '', '');
  secs := Trunc(LevelTime);
  DrawText(PChar(Format('SHELLS  %2d / %d', [Ammo, MaxAmmo])), 1032, BAR_Y + 24, 20, C(230, 200, 60));
  DrawText(PChar(Format('TIME    %d:%.2d', [secs div 60, secs mod 60])), 1032, BAR_Y + 54, 20, C(200, 200, 200));
  DrawText('TAB  MAP', 1032, BAR_Y + 84, 20, C(140, 140, 140));
end;

procedure DrawMinimap;
const
  CS = 10;
var
  ox, oy, x, y, i: Integer;
  ch: Char;
  col: TColor;
begin
  ox := WIN_W - MAP_W * CS - 16;
  oy := 16;
  DrawRectangle(ox - 4, oy - 4, MAP_W * CS + 8, MAP_H * CS + 8, C(0, 0, 0, 170));
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
    begin
      ch := Map[x, y];
      if ch = '.' then Continue;
      case ch of
        '#': col := C(170, 70, 50);
        '%': col := C(130, 130, 125);
        '&': col := C(80, 120, 120);
        '=': col := C(140, 95, 50);
        'X': col := C(40, 255, 80);
        'D': col := C(230, 200, 40, Round(255 - DoorOpen[x, y] * 180));
      else
        col := C(200, 200, 200);
      end;
      DrawRectangle(ox + x * CS, oy + y * CS, CS - 1, CS - 1, col);
    end;
  for i := 0 to MAX_ENTS - 1 do
    if Ents[i].Active then
    begin
      case Ents[i].Kind of
        ekImp, ekDemon:
          if Ents[i].State = esDead then col := C(100, 0, 0) else col := C(255, 40, 40);
        ekMedkit: col := C(240, 240, 240);
        ekAmmo: col := C(240, 200, 40);
        ekFireball: col := C(255, 140, 0);
      else
        Continue;
      end;
      DrawCircle(ox + Round(Ents[i].X * CS), oy + Round(Ents[i].Y * CS), 3, col);
    end;
  DrawLine(ox + Round(PX * CS), oy + Round(PY * CS),
           ox + Round((PX + DirX * 1.5) * CS), oy + Round((PY + DirY * 1.5) * CS), C(255, 255, 0));
  DrawCircle(ox + Round(PX * CS), oy + Round(PY * CS), 4, C(60, 255, 60));
end;

procedure DrawOverlay(const title, line1, line2: string; titleCol: TColor; dim: Integer);
begin
  DrawRectangle(0, 0, WIN_W, BAR_Y, C(0, 0, 0, dim));
  DrawTextCentered(title, WIN_W div 2, 170, 100, titleCol);
  DrawTextCentered(line1, WIN_W div 2, 310, 30, C(230, 230, 230));
  DrawTextCentered(line2, WIN_W div 2, 360, 24, C(200, 200, 200));
end;

procedure DrawFrame;
var
  secs: Integer;
begin
  RenderScene;
  UpdateTexture(ScreenTex, @FrameBuf[0]);

  BeginTextureMode(ViewRT);
  DrawTexture(ScreenTex, 0, 0, WHITE);
  if Mode <> gmTitle then DrawWeapon;
  if DamageFlash > 0 then DrawRectangle(0, 0, SCR_W, VIEW_H, C(255, 0, 0, Round(DamageFlash * 200)));
  if BonusFlash > 0 then DrawRectangle(0, 0, SCR_W, VIEW_H, C(255, 230, 0, Round(BonusFlash * 90)));
  if FlashT > 0 then DrawRectangle(0, 0, SCR_W, VIEW_H, C(255, 220, 150, 28));
  if Mode = gmDead then DrawRectangle(0, 0, SCR_W, VIEW_H, C(150, 0, 0, Round(Min(DeathT, 1) * 110)));
  EndTextureMode;

  BeginDrawing;
  ClearBackground(BLACK);
  // render textures are stored upside down, hence the negative source height
  DrawTexturePro(ViewRT.texture, Rect(0, 0, SCR_W, -VIEW_H), Rect(0, 0, WIN_W, BAR_Y), Vec2(0, 0), 0, WHITE);
  DrawStatusBar;
  if ShowMap and (Mode <> gmTitle) then DrawMinimap;
  if (MsgTimer > 0) and (Mode = gmPlay) then
    DrawTextShadow(MsgText, 16, 14, 24, C(230, 60, 50));

  case Mode of
    gmTitle:
      begin
        DrawRectangle(0, 0, WIN_W, BAR_Y, C(0, 0, 0, 140));
        DrawTextCentered('RAYDOOM', WIN_W div 2, 110, 140, C(200, 25, 20));
        DrawTextCentered('A Doom-style shooter in Free Pascal + raylib', WIN_W div 2, 260, 28, C(230, 200, 150));
        DrawTextCentered('WASD move   MOUSE turn   CLICK/CTRL fire   E/SPACE open doors', WIN_W div 2, 340, 22, C(210, 210, 210));
        DrawTextCentered('SHIFT run   TAB map   ESC pause', WIN_W div 2, 372, 22, C(210, 210, 210));
        DrawTextCentered('Find the red EXIT switch and press E on it.', WIN_W div 2, 420, 22, C(120, 255, 120));
        if Frac(GetTime) < 0.6 then
          DrawTextCentered('Click or press ENTER to start', WIN_W div 2, 500, 32, C(255, 255, 255));
      end;
    gmPaused:
      DrawOverlay('PAUSED', 'ESC or click to resume', 'Q to quit', C(255, 255, 255), 150);
    gmDead:
      if DeathT > 1 then
        DrawOverlay('YOU DIED', 'Press R or ENTER to restart', Format('Kills %d/%d', [Kills, TotalKills]),
          C(220, 20, 20), 60);
    gmWon:
      begin
        secs := Trunc(LevelTime);
        DrawOverlay('LEVEL COMPLETE',
          Format('Kills %d/%d     Time %d:%.2d', [Kills, TotalKills, secs div 60, secs mod 60]),
          'Press R or ENTER to play again', C(240, 200, 40), 170);
      end;
  end;
  EndDrawing;
end;

{ ================================================================ main loop }

procedure StartPlaying;
begin
  Mode := gmPlay;
  DisableCursor;
  SkipMouse := True;
end;

procedure UpdateGame(dt: Single);
begin
  DamageFlash := Max(0, DamageFlash - dt * 1.5);
  BonusFlash := Max(0, BonusFlash - dt * 2);
  FlashT := FlashT - dt;
  Recoil := Max(0, Recoil - dt * 6);
  MsgTimer := MsgTimer - dt;
  GrinT := GrinT - dt;
  PainFaceT := PainFaceT - dt;

  case Mode of
    gmTitle:
      begin
        PAngle := PAngle + dt * 0.2;
        UpdateDirs;
        if IsKeyPressed(KEY_ENTER) or IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
        begin
          StartPlaying;
          FireCD := 0.3;     // don't fire on the click that started the game
          ShowMessage('Find the EXIT switch!');
        end;
      end;
    gmPlay:
      if IsKeyPressed(KEY_ESCAPE) then
      begin
        Mode := gmPaused;
        EnableCursor;
      end
      else
      begin
        LevelTime := LevelTime + dt;
        UpdatePlayer(dt);
        UpdateDoors(dt);
        UpdateEntities(dt);
      end;
    gmPaused:
      if IsKeyPressed(KEY_Q) then
        QuitRequested := True
      else if IsKeyPressed(KEY_ESCAPE) or IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
      begin
        StartPlaying;
        FireCD := 0.3;
      end;
    gmDead:
      begin
        DeathT := DeathT + dt;
        CamH := 0.5 - Min(DeathT * 1.2, 1) * 0.38;
        UpdateDoors(dt);
        UpdateEntities(dt);
        if (DeathT > 1) and (IsKeyPressed(KEY_R) or IsKeyPressed(KEY_ENTER)) then
        begin
          LoadLevel;
          StartPlaying;
        end;
      end;
    gmWon:
      if IsKeyPressed(KEY_R) or IsKeyPressed(KEY_ENTER) then
      begin
        LoadLevel;
        StartPlaying;
      end;
  end;
end;

// --autotest: scripted run that saves screenshots and exits (used to verify the build)
procedure AutoTestStep(frame: Integer);
begin
  case frame of
    1: begin Mode := gmPlay; PAngle := 0.3; UpdateDirs; end;
    30: TakeScreenshot('autotest_1.png');
    31: begin PX := 11.5; PY := 2.5; PAngle := -Pi / 2 + 0.2; UpdateDirs; end;
    60: begin PX := 12.0; PY := 6.5; PAngle := -Pi / 2 - 0.3; UpdateDirs; FireCD := 0; FireShotgun; end;
    62: TakeScreenshot('autotest_2.png');
    63: begin PX := 26.5; PY := 20.5; PAngle := -0.6; UpdateDirs; ShowMap := True; end;
    90: TakeScreenshot('autotest_3.png');
    91: QuitRequested := True;
  end;
end;

procedure RunGame;
var
  img: TImage;
  dt: Single;
  frame: Integer;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Randomize;

  // Usage: RayDoom [--autotest] [mapfile]
  // Without a map argument, level.map next to the exe is used if present, else the built-in level.
  AutoTest := False;
  LevelName := '';
  for frame := 1 to ParamCount do
    if ParamStr(frame) = '--autotest' then
      AutoTest := True
    else
      LevelName := ParamStr(frame);
  if (LevelName = '') and not AutoTest and FileExists(MapPath(DEFAULT_MAP_FILE)) then
    LevelName := MapPath(DEFAULT_MAP_FILE);
  // sounds.cfg / characters.cfg from the editors override the built-in defaults
  LoadSfxConfig(ExePath(SFX_CONFIG_FILE));
  LoadCharConfig(ExePath(CHAR_CONFIG_FILE));
  if (LevelName = '') or not LoadMapFile(LevelName, LevelGrid) then
  begin
    DefaultGrid(LevelGrid);
    LevelName := 'built-in level';
  end;

  SetTraceLogLevel(LOG_WARNING);
  SetConfigFlags(FLAG_VSYNC_HINT);
  InitWindow(WIN_W, WIN_H, PChar('RayDoom - ' + ExtractFileName(LevelName)));
  SetExitKey(KEY_NULL);
  SetTargetFPS(60);
  InitAudioDevice;

  Proj := (SCR_W / 2) / FOV_PLANE;
  GenerateTextures;
  LoadSounds;
  img := GenImageColor(SCR_W, VIEW_H, BLACK);
  ScreenTex := LoadTextureFromImage(img);
  UnloadImage(img);
  ViewRT := LoadRenderTexture(SCR_W, VIEW_H);

  LoadLevel;
  Mode := gmTitle;
  frame := 0;
  while not WindowShouldClose and not QuitRequested do
  begin
    Inc(frame);
    if AutoTest then AutoTestStep(frame);
    dt := GetFrameTime;
    if dt > 0.05 then dt := 0.05;
    UpdateGame(dt);
    DrawFrame;
  end;

  UnloadRenderTexture(ViewRT);
  UnloadTexture(ScreenTex);
  UnloadSounds;
  CloseAudioDevice;
  CloseWindow;
end;

end.
