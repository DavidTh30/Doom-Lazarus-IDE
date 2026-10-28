unit doommap;

{ Map format shared by the game and the map editor.

  A map is a plain text file of MAP_H lines with MAP_W characters each.
  Lines starting with ';' are comments. Legend:
      #  brick wall      %  stone wall     &  tech wall      =  wood wall
      D  door            X  exit switch    .  floor          P  player start
      i  imp             d  demon          h  medikit        a  shells
      l  tech lamp }

{$mode objfpc}{$H+}

interface

const
  MAP_W = 32;
  MAP_H = 24;
  DEFAULT_MAP_FILE = 'level.map';

  DefaultLevel: array[0..MAP_H - 1] of string = (
    '################################',
    '#P.....#........%..............%',
    '#......#..i.....%....i.....a...%',
    '#..h...D........D..............%',
    '#......#...l....%..............%',
    '#......#........%%%%%%%D%%%%%%%%',
    '###D####....a...%..............%',
    '#......#........%...i......d...%',
    '#..a...######D###..............%',
    '#......&........%..........h...%',
    '#..i...&....d...%%%%%%%%%%D%%%%%',
    '#......&..........&&&&&.......&&',
    '#..l...&....l.....&...&...i...&&',
    '###D####..........D...&.......&&',
    '#......#..a....i..&...&&&&D&&&&&',
    '#..d...#..........&.h.&.......&&',
    '#......D..........&...&...l...&&',
    '#==D====....l.....&&D&&.......&&',
    '=......=..............&..i....X&',
    '=..h...=..............&...d...&&',
    '=......=......d.......&.....a.&&',
    '=..i...=..............&..i....&&',
    '=..a...=......l.......&.......&&',
    '================================'
  );

type
  TMapGrid = array[0..MAP_W - 1, 0..MAP_H - 1] of Char;

function IsWallTile(ch: Char): Boolean;
function IsKnownTile(ch: Char): Boolean;
function GridCell(const g: TMapGrid; x, y: Integer): Char;
procedure DefaultGrid(out g: TMapGrid);
procedure EmptyGrid(out g: TMapGrid);
function LoadMapFile(const fileName: string; out g: TMapGrid): Boolean;
function SaveMapFile(const fileName: string; const g: TMapGrid): Boolean;
// Relative names are resolved against the folder of the running executable
function MapPath(const fileName: string): string;

implementation

uses
  SysUtils;

function IsWallTile(ch: Char): Boolean;
begin
  Result := ch in ['#', '%', '&', '=', 'X'];
end;

function IsKnownTile(ch: Char): Boolean;
begin
  Result := ch in ['#', '%', '&', '=', 'X', 'D', '.', 'P', 'i', 'd', 'h', 'a', 'l'];
end;

function GridCell(const g: TMapGrid; x, y: Integer): Char;
begin
  if (x < 0) or (y < 0) or (x >= MAP_W) or (y >= MAP_H) then
    Result := '#'
  else
    Result := g[x, y];
end;

procedure RowsToGrid(const rows: array of string; out g: TMapGrid);
var
  x, y: Integer;
  ch: Char;
begin
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
    begin
      if (y <= High(rows)) and (x < Length(rows[y])) then
      begin
        ch := rows[y][x + 1];
        if not IsKnownTile(ch) then ch := '.';
      end
      else
        ch := '#';
      g[x, y] := ch;
    end;
end;

procedure DefaultGrid(out g: TMapGrid);
begin
  RowsToGrid(DefaultLevel, g);
end;

procedure EmptyGrid(out g: TMapGrid);
var
  x, y: Integer;
begin
  for y := 0 to MAP_H - 1 do
    for x := 0 to MAP_W - 1 do
      if (x = 0) or (y = 0) or (x = MAP_W - 1) or (y = MAP_H - 1) then
        g[x, y] := '#'
      else
        g[x, y] := '.';
  g[2, 2] := 'P';
end;

function LoadMapFile(const fileName: string; out g: TMapGrid): Boolean;
var
  f: TextFile;
  rows: array of string;
  line: string;
begin
  Result := False;
  if not FileExists(fileName) then Exit;
  rows := nil;
  AssignFile(f, fileName);
  {$I-}
  Reset(f);
  {$I+}
  if IOResult <> 0 then Exit;
  try
    while not Eof(f) and (Length(rows) < MAP_H) do
    begin
      ReadLn(f, line);
      if (line <> '') and (line[1] = ';') then Continue;
      SetLength(rows, Length(rows) + 1);
      rows[High(rows)] := line;
    end;
  finally
    CloseFile(f);
  end;
  RowsToGrid(rows, g);
  Result := True;
end;

function SaveMapFile(const fileName: string; const g: TMapGrid): Boolean;
var
  f: TextFile;
  x, y: Integer;
  line: string;
begin
  AssignFile(f, fileName);
  {$I-}
  Rewrite(f);
  {$I+}
  if IOResult <> 0 then Exit(False);
  try
    WriteLn(f, '; RayDoom map ', MAP_W, 'x', MAP_H);
    for y := 0 to MAP_H - 1 do
    begin
      SetLength(line, MAP_W);
      for x := 0 to MAP_W - 1 do
        line[x + 1] := g[x, y];
      WriteLn(f, line);
    end;
  finally
    CloseFile(f);
  end;
  Result := True;
end;

function MapPath(const fileName: string): string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + fileName);
  if (ExtractFileDrive(fileName) <> '') or ((fileName <> '') and (fileName[1] in ['\', '/'])) then
    Result := ExpandFileName(fileName);
end;

end.
