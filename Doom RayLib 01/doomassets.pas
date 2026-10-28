unit doomassets;

{ Procedurally generated textures, sprites and sound effects.
  Nothing is loaded from disk: every pixel and every sample is computed at startup. }

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  raylib, doomchars;

const
  TEX_SIZE = 64;

  TEX_BRICK = 0;
  TEX_STONE = 1;
  TEX_TECH  = 2;
  TEX_WOOD  = 3;
  TEX_DOOR  = 4;
  TEX_EXIT  = 5;
  TEX_FLOOR = 6;
  TEX_CEIL  = 7;
  NUM_TEX   = 8;

  // Monster animation frames (added to SPR_IMP / SPR_DEMON)
  FR_WALK1  = 0;
  FR_WALK2  = 1;
  FR_ATTACK = 2;
  FR_PAIN   = 3;
  FR_DEAD   = 4;

  SPR_IMP    = 0;
  SPR_DEMON  = 5;
  SPR_MEDKIT = 10;
  SPR_AMMO   = 11;
  SPR_FIRE1  = 12;
  SPR_FIRE2  = 13;
  SPR_LAMP   = 14;
  SPR_PUFF   = 15;
  SPR_BLOOD  = 16;
  NUM_SPR    = 17;

type
  // Pixels are stored as little-endian RGBA (same layout raylib expects), index = x + y * TEX_SIZE
  TTexPixels = array[0..TEX_SIZE * TEX_SIZE - 1] of Cardinal;
  PTexPixels = ^TTexPixels;

var
  WallTex: array[0..NUM_TEX - 1] of TTexPixels;
  SprTex: array[0..NUM_SPR - 1] of TTexPixels;

function RGBA(r, g, b: Integer; a: Integer = 255): Cardinal;
procedure GenerateTextures;
// Draws one monster frame from its character definition (also used by the character editor)
procedure DrawMonster(var t: TTexPixels; frame: Integer; const d: TMonsterDef);

implementation

uses
  Math;

{ ---------------------------------------------------------------- helpers }

function ClampI(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0
  else if v > 255 then Result := 255
  else Result := v;
end;

function RGBA(r, g, b: Integer; a: Integer): Cardinal;
begin
  Result := Cardinal(ClampI(r)) or (Cardinal(ClampI(g)) shl 8) or
            (Cardinal(ClampI(b)) shl 16) or (Cardinal(ClampI(a)) shl 24);
end;

// Colour from float components times a brightness factor
function Shd(r, g, b, k: Single): Cardinal;
begin
  Result := RGBA(Round(r * k), Round(g * k), Round(b * k));
end;

function Hash2(ix, iy, seed: Integer): Single;
var
  h: Cardinal;
begin
  h := Cardinal((QWord(Cardinal(ix)) * 374761393 + QWord(Cardinal(iy)) * 668265263 +
                 QWord(Cardinal(seed)) * 2246822519) and $FFFFFFFF);
  h := Cardinal((QWord(h xor (h shr 13)) * 1274126177) and $FFFFFFFF);
  h := h xor (h shr 16);
  Result := (h and $FFFF) / 65535.0;
end;

// Tileable smooth value noise in 0..1
function Noise(x, y, cell, seed: Integer): Single;
var
  n, ix, iy, ix1, iy1: Integer;
  fx, fy, a, b, c, d, top, bot: Single;
begin
  n := TEX_SIZE div cell;
  ix := x div cell;
  iy := y div cell;
  fx := (x mod cell) / cell;
  fy := (y mod cell) / cell;
  ix1 := (ix + 1) mod n;
  iy1 := (iy + 1) mod n;
  a := Hash2(ix, iy, seed);
  b := Hash2(ix1, iy, seed);
  c := Hash2(ix, iy1, seed);
  d := Hash2(ix1, iy1, seed);
  fx := fx * fx * (3 - 2 * fx);
  fy := fy * fy * (3 - 2 * fy);
  top := a + (b - a) * fx;
  bot := c + (d - c) * fx;
  Result := top + (bot - top) * fy;
end;

function Fbm(x, y, seed: Integer): Single;
begin
  Result := Noise(x, y, 16, seed) * 0.5 + Noise(x, y, 8, seed + 1) * 0.3 +
            Noise(x, y, 4, seed + 2) * 0.2;
end;

procedure PutPx(var t: TTexPixels; x, y: Integer; c: Cardinal); inline;
begin
  if (x >= 0) and (y >= 0) and (x < TEX_SIZE) and (y < TEX_SIZE) then
    t[x + y * TEX_SIZE] := c;
end;

procedure FillRectT(var t: TTexPixels; x0, y0, x1, y1, r, g, b: Integer; noiseAmt: Single = 0.15);
var
  x, y: Integer;
  k: Single;
begin
  for y := y0 to y1 do
    for x := x0 to x1 do
    begin
      k := 1 - noiseAmt + Hash2(x, y, 77) * noiseAmt * 2;
      PutPx(t, x, y, Shd(r, g, b, k));
    end;
end;

// Filled ellipse, optionally shaded like a sphere lit from the upper left
procedure FillEllipse(var t: TTexPixels; cx, cy, rx, ry: Single; r, g, b: Integer; shaded: Boolean = True);
var
  x, y: Integer;
  dx, dy, d, l: Single;
begin
  for y := Floor(cy - ry) to Ceil(cy + ry) do
    for x := Floor(cx - rx) to Ceil(cx + rx) do
    begin
      dx := (x + 0.5 - cx) / rx;
      dy := (y + 0.5 - cy) / ry;
      d := dx * dx + dy * dy;
      if d <= 1 then
      begin
        if shaded then
        begin
          l := 1.1 - 0.4 * Sqrt(d) - 0.2 * (dx + dy) + (Hash2(x, y, 5) - 0.5) * 0.12;
          if l < 0.3 then l := 0.3;
          if l > 1.3 then l := 1.3;
        end
        else
          l := 1;
        PutPx(t, x, y, Shd(r, g, b, l));
      end;
    end;
end;

procedure ClearTex(var t: TTexPixels);
begin
  FillChar(t, SizeOf(t), 0);
end;

{ ---------------------------------------------------------------- wall / flat textures }

procedure GenBrick(var t: TTexPixels);
var
  x, y, row, off, bx, by: Integer;
  n, v, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      row := y div 16;
      off := (row mod 2) * 16;
      bx := (x + off) mod 32;
      by := y mod 16;
      n := Fbm(x, y, 10) * 0.6 + Hash2(x, y, 12) * 0.4;
      if (by < 2) or (bx < 2) then
        t[x + y * 64] := Shd(80, 75, 70, 0.7 + n * 0.5)
      else
      begin
        v := Hash2(((x + off) div 32) mod 2, row, 13);
        k := 0.65 + n * 0.55;
        if by = 2 then k := k * 1.25;
        if (by = 15) or (bx = 31) then k := k * 0.7;
        t[x + y * 64] := Shd(140 + v * 40, 55 + v * 15, 38, k);
      end;
    end;
end;

procedure GenStone(var t: TTexPixels);
var
  x, y, row, off, bx, by: Integer;
  n, v, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      row := y div 32;
      off := (row mod 2) * 20;
      bx := (x + off) mod 32;
      by := y mod 32;
      n := Fbm(x, y, 20);
      v := Hash2(((x + off) div 32) mod 2, row, 21);
      k := 0.55 + n * 0.6 + v * 0.15;
      if (bx = 0) or (by = 0) then k := 0.3
      else if (bx = 1) or (by = 1) then k := k * 1.3
      else if (bx = 31) or (by = 31) then k := k * 0.65;
      t[x + y * 64] := Shd(125, 122, 118, k);
    end;
end;

procedure GenTech(var t: TTexPixels);
var
  x, y, px, py: Integer;
  n, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      px := x mod 32;
      py := y mod 32;
      n := Fbm(x, y, 30);
      k := 0.75 + n * 0.35;
      if (px = 0) or (py = 0) then k := k * 1.35
      else if (px = 31) or (py = 31) then k := k * 0.55;
      t[x + y * 64] := Shd(95, 108, 112, k);
      // rivets
      if ((px = 4) or (px = 27)) and ((py = 4) or (py = 27)) then
        t[x + y * 64] := Shd(170, 175, 180, 1);
    end;
  // dark stripe with green status lights
  for y := 28 to 35 do
    for x := 0 to 63 do
    begin
      t[x + y * 64] := Shd(35, 38, 40, 0.8 + Hash2(x, y, 31) * 0.3);
      if (y >= 30) and (y <= 33) and ((x mod 8) in [2..5]) then
      begin
        if (x div 8) mod 3 = 0 then
          t[x + y * 64] := RGBA(255, 70, 40)
        else
          t[x + y * 64] := RGBA(60, 255, 90);
      end;
    end;
end;

procedure GenWood(var t: TTexPixels);
var
  x, y, plank, px: Integer;
  n, grain, v, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      plank := x div 16;
      px := x mod 16;
      v := Hash2(plank, 0, 41);
      n := Fbm(x, y, 40);
      grain := Sin((y + v * 40) * 0.35 + n * 6 + px * 0.25) * 0.5 + 0.5;
      k := 0.6 + grain * 0.3 + n * 0.25;
      if px = 0 then k := 0.3
      else if px = 15 then k := k * 0.7
      else if px = 1 then k := k * 1.2;
      t[x + y * 64] := Shd(125 + v * 25, 80 + v * 10, 42, k);
    end;
end;

procedure GenDoor(var t: TTexPixels);
var
  x, y: Integer;
  n, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      n := Fbm(x, y, 50);
      k := 0.75 + n * 0.3;
      if (x mod 8 = 0) then k := k * 0.6
      else if (x mod 8 = 1) then k := k * 1.2;
      if (x < 4) or (x > 59) or (y < 4) or (y > 59) then k := k * 0.55;
      t[x + y * 64] := Shd(135, 135, 145, k);
    end;
  // hazard stripe band
  for y := 26 to 37 do
    for x := 4 to 59 do
      if ((x + y) div 4) mod 2 = 0 then
        t[x + y * 64] := Shd(230, 190, 30, 0.85 + Hash2(x, y, 51) * 0.2)
      else
        t[x + y * 64] := Shd(30, 30, 30, 1);
end;

procedure GenExit(var t: TTexPixels);
var
  x, y: Integer;
  d: Single;
begin
  GenTech(t);
  // recessed panel
  FillRectT(t, 14, 8, 49, 55, 40, 40, 45, 0.1);
  // green screen
  FillRectT(t, 18, 12, 45, 24, 40, 220, 80, 0.25);
  // "EXIT" style bars on the screen
  FillRectT(t, 21, 16, 24, 20, 10, 80, 20, 0);
  FillRectT(t, 27, 16, 29, 20, 10, 80, 20, 0);
  FillRectT(t, 32, 16, 33, 20, 10, 80, 20, 0);
  FillRectT(t, 36, 16, 42, 17, 10, 80, 20, 0);
  FillRectT(t, 38, 18, 40, 20, 10, 80, 20, 0);
  // big red switch
  for y := 28 to 52 do
    for x := 18 to 45 do
    begin
      d := Sqrt(Sqr(x + 0.5 - 32) + Sqr(y + 0.5 - 40));
      if d < 10 then
        t[x + y * 64] := Shd(255, 30, 20, 1.15 - d / 14 - (x + y - 72) * 0.01)
      else if d < 12 then
        t[x + y * 64] := Shd(90, 90, 95, 1);
    end;
end;

procedure GenFloor(var t: TTexPixels);
var
  x, y, tx, ty: Integer;
  n, v, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      tx := x mod 16;
      ty := y mod 16;
      n := Fbm(x, y, 60);
      v := Hash2(x div 16, y div 16, 61);
      k := 0.6 + n * 0.45 + v * 0.12;
      if (tx = 0) or (ty = 0) then k := 0.35
      else if (tx = 1) or (ty = 1) then k := k * 1.15;
      t[x + y * 64] := Shd(105, 92, 75, k);
    end;
end;

procedure GenCeil(var t: TTexPixels);
var
  x, y, px, py: Integer;
  n, k: Single;
begin
  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      px := x mod 32;
      py := y mod 32;
      n := Fbm(x, y, 70);
      k := 0.55 + n * 0.35;
      if (px = 0) or (py = 0) then k := 0.3;
      t[x + y * 64] := Shd(110, 110, 115, k);
      // light fixtures in alternating panels
      if ((x div 32 + y div 32) mod 2 = 0) and (px >= 10) and (px <= 21) and (py >= 10) and (py <= 21) then
      begin
        if (px = 10) or (px = 21) or (py = 10) or (py = 21) then
          t[x + y * 64] := Shd(90, 90, 95, 1)
        else
          t[x + y * 64] := Shd(255, 250, 215, 0.92 + Hash2(x, y, 71) * 0.08);
      end;
    end;
end;

{ ---------------------------------------------------------------- sprites }

procedure TintPain(var t: TTexPixels);
var
  i: Integer;
  c, r, g, b: Cardinal;
begin
  for i := 0 to High(t) do
  begin
    c := t[i];
    if (c shr 24) <> 0 then
    begin
      r := c and $FF;
      g := (c shr 8) and $FF;
      b := (c shr 16) and $FF;
      t[i] := RGBA(Integer(r) + 90, g * 6 div 10, b * 6 div 10);
    end;
  end;
end;

procedure DrawMonster(var t: TTexPixels; frame: Integer; const d: TMonsterDef);
var
  br, bg, bb, er, eg, eb, i, nt, tx: Integer;
  bw, bh, hs, arm, leg, horn, mouth, legOff, legCY, bodyCY, headCY, armY, topY, faceY, mouthY,
  eyeDX, hornDX, mouthH, need, fy: Single;
  ranged, spikes: Boolean;
begin
  ClearTex(t);
  br := Round(d[MP_BODYR]); bg := Round(d[MP_BODYG]); bb := Round(d[MP_BODYB]);
  er := Round(d[MP_EYER]); eg := Round(d[MP_EYEG]); eb := Round(d[MP_EYEB]);
  bw := d[MP_BODYW];
  bh := d[MP_BODYH];
  hs := d[MP_HEAD];
  arm := d[MP_ARMS];
  leg := d[MP_LEGS];
  horn := d[MP_HORNS];
  mouth := d[MP_MOUTH];
  ranged := d[MP_RANGED] >= 0.5;
  spikes := d[MP_SPIKES] >= 0.5;

  if frame = FR_DEAD then
  begin
    FillEllipse(t, 32, 60, Min(30, bw + 10), 4, 110, 0, 0, False);
    FillEllipse(t, 30, 56, Min(28, bw * 0.9 + 4), 6, br * 2 div 3, bg * 2 div 3, bb * 2 div 3);
    FillEllipse(t, 44, 57, 8, 4, br div 2, bg div 2, bb div 2);
    FillEllipse(t, 26, 55, 7, 3, 160, 10, 10);
    FillEllipse(t, 18, 58, 3, 2, 230, 230, 210);
    FillEllipse(t, 37, 53, 2, 2, 230, 230, 210);
    FillEllipse(t, 48, 60, 3, 1.5, 230, 230, 210);
    Exit;
  end;

  legOff := 0;
  if frame = FR_WALK1 then legOff := -3;
  if frame = FR_WALK2 then legOff := 3;

  // vertical layout from the feet up; push down if the head would leave the sprite
  legCY := 63 - leg;
  bodyCY := 63 - 2 * leg - bh * 0.45 + 4;
  if hs > 0 then need := bh + hs * 1.6 + horn else need := bh + horn;
  if bodyCY - need < 1 then bodyCY := 1 + need;

  FillEllipse(t, 32 - bw * 0.55, legCY + legOff, 6, leg, br * 3 div 4, bg * 3 div 4, bb * 3 div 4);
  FillEllipse(t, 32 + bw * 0.55, legCY - legOff, 6, leg, br * 3 div 4, bg * 3 div 4, bb * 3 div 4);

  if (frame = FR_ATTACK) and ranged then armY := bodyCY - bh - arm else armY := bodyCY;
  if arm > 0 then
  begin
    FillEllipse(t, 32 - bw - arm * 0.4, armY, arm, arm * 2, br * 4 div 5, bg * 4 div 5, bb * 4 div 5);
    FillEllipse(t, 32 + bw + arm * 0.4, armY, arm, arm * 2, br * 4 div 5, bg * 4 div 5, bb * 4 div 5);
  end;

  FillEllipse(t, 32, bodyCY, bw, bh, br, bg, bb);
  if spikes then
  begin
    FillEllipse(t, 32 - bw * 0.7, bodyCY - bh * 0.7, 2.5, 4, 230, 225, 200);
    FillEllipse(t, 32 + bw * 0.7, bodyCY - bh * 0.7, 2.5, 4, 230, 225, 200);
    FillEllipse(t, 32 - bw * 0.4, bodyCY + bh * 0.25, 1.5, 2.5, 230, 225, 200);
    FillEllipse(t, 32 + bw * 0.4, bodyCY + bh * 0.45, 1.5, 2.5, 230, 225, 200);
  end;

  // head, or a face on the body when the head size is 0
  if hs > 0 then
  begin
    headCY := bodyCY - bh - hs * 0.6;
    FillEllipse(t, 32, headCY, hs, hs, br, bg, bb);
    topY := headCY - hs;
    hornDX := hs * 0.7;
    eyeDX := hs * 0.45;
    faceY := headCY - hs * 0.1;
    mouthY := headCY + hs * 0.5;
  end
  else
  begin
    topY := bodyCY - bh;
    hornDX := bw * 0.6;
    eyeDX := bw * 0.35;
    faceY := bodyCY - bh * 0.55;
    mouthY := bodyCY;
  end;

  if horn > 0 then
  begin
    FillEllipse(t, 32 - hornDX, topY - horn * 0.5 + 1, 2, horn, 240, 230, 200);
    FillEllipse(t, 32 + hornDX, topY - horn * 0.5 + 1, 2, horn, 240, 230, 200);
  end;
  FillEllipse(t, 32 - eyeDX, faceY, 2.2, 1.8, er, eg, eb, False);
  FillEllipse(t, 32 + eyeDX, faceY, 2.2, 1.8, er, eg, eb, False);

  if mouth > 0 then
  begin
    mouthH := mouth * 0.3;
    if (frame = FR_ATTACK) and not ranged then mouthH := mouth * 0.7;
    if mouthH < 1.2 then mouthH := 1.2;
    FillEllipse(t, 32, mouthY, mouth, mouthH, 90, 0, 0, False);
    if mouth >= 7 then
    begin
      nt := Trunc(mouth / 2);
      for i := 0 to nt - 1 do
      begin
        tx := Round(32 - mouth + 2 + i * 4);
        FillRectT(t, tx, Round(mouthY - mouthH), tx + 1, Round(mouthY - mouthH) + 3, 240, 240, 220, 0.05);
        FillRectT(t, tx, Round(mouthY + mouthH) - 3, tx + 1, Round(mouthY + mouthH), 240, 240, 220, 0.05);
      end;
    end;
  end;

  // ranged attackers conjure a fireball between their raised claws
  if ranged and (frame = FR_ATTACK) then
  begin
    fy := Max(6, armY - arm * 2 - 2);
    FillEllipse(t, 32, fy, 7, 6, 255, 140, 20, False);
    FillEllipse(t, 32, fy, 4, 3, 255, 240, 170, False);
  end;

  if frame = FR_PAIN then
    TintPain(t);
end;

procedure GenSprites;
var
  i: Integer;
begin
  for i := 0 to 4 do
  begin
    DrawMonster(SprTex[SPR_IMP + i], i, MonDefs[MON_IMP]);
    DrawMonster(SprTex[SPR_DEMON + i], i, MonDefs[MON_DEMON]);
  end;

  // medikit
  ClearTex(SprTex[SPR_MEDKIT]);
  FillRectT(SprTex[SPR_MEDKIT], 14, 34, 50, 63, 120, 120, 120);
  FillRectT(SprTex[SPR_MEDKIT], 16, 36, 48, 61, 230, 230, 230);
  FillRectT(SprTex[SPR_MEDKIT], 29, 39, 35, 58, 210, 10, 10);
  FillRectT(SprTex[SPR_MEDKIT], 22, 45, 42, 51, 210, 10, 10);

  // box of shells
  ClearTex(SprTex[SPR_AMMO]);
  for i := 0 to 4 do
  begin
    FillRectT(SprTex[SPR_AMMO], 16 + i * 7, 40, 20 + i * 7, 47, 210, 30, 25);
    FillRectT(SprTex[SPR_AMMO], 16 + i * 7, 46, 20 + i * 7, 48, 220, 180, 60);
  end;
  FillRectT(SprTex[SPR_AMMO], 12, 48, 52, 63, 140, 25, 20);
  FillRectT(SprTex[SPR_AMMO], 12, 52, 52, 55, 210, 175, 50);

  // fireball (two flicker frames)
  ClearTex(SprTex[SPR_FIRE1]);
  FillEllipse(SprTex[SPR_FIRE1], 32, 32, 15, 13, 230, 60, 10, False);
  FillEllipse(SprTex[SPR_FIRE1], 31, 31, 10, 9, 255, 150, 30, False);
  FillEllipse(SprTex[SPR_FIRE1], 30, 30, 5, 4, 255, 245, 190, False);
  ClearTex(SprTex[SPR_FIRE2]);
  FillEllipse(SprTex[SPR_FIRE2], 32, 33, 13, 15, 230, 50, 10, False);
  FillEllipse(SprTex[SPR_FIRE2], 33, 32, 9, 10, 255, 160, 40, False);
  FillEllipse(SprTex[SPR_FIRE2], 33, 31, 4, 5, 255, 250, 200, False);

  // tech lamp
  ClearTex(SprTex[SPR_LAMP]);
  FillRectT(SprTex[SPR_LAMP], 23, 57, 41, 63, 55, 55, 60);
  FillRectT(SprTex[SPR_LAMP], 29, 18, 35, 57, 90, 92, 100);
  FillRectT(SprTex[SPR_LAMP], 29, 18, 30, 57, 140, 142, 150);
  FillRectT(SprTex[SPR_LAMP], 25, 14, 39, 18, 70, 70, 80);
  FillEllipse(SprTex[SPR_LAMP], 32, 8, 7, 6, 170, 225, 255, False);
  FillEllipse(SprTex[SPR_LAMP], 32, 8, 4, 3, 255, 255, 255, False);

  // bullet puff
  ClearTex(SprTex[SPR_PUFF]);
  FillEllipse(SprTex[SPR_PUFF], 32, 32, 9, 9, 150, 150, 150);
  FillEllipse(SprTex[SPR_PUFF], 30, 30, 5, 5, 215, 215, 210);

  // blood splat
  ClearTex(SprTex[SPR_BLOOD]);
  FillEllipse(SprTex[SPR_BLOOD], 32, 32, 8, 8, 180, 0, 0);
  FillEllipse(SprTex[SPR_BLOOD], 22, 26, 3, 3, 160, 0, 0);
  FillEllipse(SprTex[SPR_BLOOD], 42, 38, 3, 3, 160, 0, 0);
  FillEllipse(SprTex[SPR_BLOOD], 36, 22, 2, 2, 160, 0, 0);
end;

procedure GenerateTextures;
begin
  GenBrick(WallTex[TEX_BRICK]);
  GenStone(WallTex[TEX_STONE]);
  GenTech(WallTex[TEX_TECH]);
  GenWood(WallTex[TEX_WOOD]);
  GenDoor(WallTex[TEX_DOOR]);
  GenExit(WallTex[TEX_EXIT]);
  GenFloor(WallTex[TEX_FLOOR]);
  GenCeil(WallTex[TEX_CEIL]);
  GenSprites;
end;

end.
