program RayDoomEditor;

{ Map editor for RayDoom. Usage: RayDoomEditor [mapfile]  (default: level.map)
  raylib.dll (x64) must be in the same folder as the executable. }

{$mode objfpc}{$H+}

uses
  mapeditor;

begin
  RunEditor;
end.
