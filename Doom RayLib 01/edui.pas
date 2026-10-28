unit edui;

{ Tiny immediate-mode widgets (buttons, parameter sliders) shared by the
  sound editor and the character editor. }

{$mode objfpc}{$H+}

interface

uses
  raylib, doomparams;

var
  MouseX, MouseY: Integer;
  UiBlocked: Boolean;       // a modal dialog is open: widgets ignore the mouse
  EditStarted: Boolean;     // a slider edit began this frame (time to take an undo snapshot)
  EditFinished: Boolean;    // a slider edit was completed this frame (time to rebuild assets)

function C(r, g, b: Integer; a: Integer = 255): TColor; inline;
procedure UiBeginFrame;
function MouseIn(x, y, w, h: Integer): Boolean;
function CtrlDown: Boolean;
function Button(x, y, w, h: Integer; const lbl: string; active: Boolean = False): Boolean;
// Draggable slider for one parameter. Wheel nudges, right click resets to defVal.
// Returns True when the value changed this frame.
function Slider(id, x, y, w: Integer; const info: TParamInfo; var v: Single; defVal: Single;
  const valueText: string = ''): Boolean;
procedure SectionTitle(const s: string; x, y: Integer);

implementation

uses
  Math;

var
  ActiveSlider: Integer = -1;

function C(r, g, b: Integer; a: Integer): TColor;
begin
  Result := ColorRGBA(r, g, b, a);
end;

procedure UiBeginFrame;
var
  mp: TVector2;
begin
  mp := GetMousePosition;
  MouseX := Round(mp.x);
  MouseY := Round(mp.y);
  EditStarted := False;
  EditFinished := False;
  if (ActiveSlider >= 0) and not IsMouseButtonDown(MOUSE_BUTTON_LEFT) then
  begin
    ActiveSlider := -1;
    EditFinished := True;
  end;
end;

function MouseIn(x, y, w, h: Integer): Boolean;
begin
  Result := (MouseX >= x) and (MouseY >= y) and (MouseX < x + w) and (MouseY < y + h);
end;

function CtrlDown: Boolean;
begin
  Result := IsKeyDown(KEY_LEFT_CONTROL) or IsKeyDown(KEY_RIGHT_CONTROL);
end;

function Button(x, y, w, h: Integer; const lbl: string; active: Boolean): Boolean;
var
  hot: Boolean;
  col: TColor;
  size: Integer;
begin
  hot := MouseIn(x, y, w, h) and not UiBlocked;
  if active then col := C(170, 35, 28)
  else if hot then col := C(88, 88, 94)
  else col := C(60, 60, 66);
  DrawRectangle(x, y, w, h, col);
  DrawRectangle(x, y, w, 2, C(120, 120, 128));
  DrawRectangleLines(x, y, w, h, C(20, 20, 22));
  size := 18;
  while (size > 10) and (MeasureText(PChar(lbl), size) > w - 8) do Dec(size);
  DrawText(PChar(lbl), x + (w - MeasureText(PChar(lbl), size)) div 2, y + (h - size) div 2, size, C(235, 235, 235));
  Result := hot and IsMouseButtonPressed(MOUSE_BUTTON_LEFT);
end;

function Slider(id, x, y, w: Integer; const info: TParamInfo; var v: Single; defVal: Single;
  const valueText: string): Boolean;
var
  tx, tw, kx: Integer;
  old, wheel, step: Single;
  hot: Boolean;
  s: string;
begin
  tx := x + 170;
  tw := w - 170 - 74;
  old := v;
  hot := MouseIn(x, y, w, 24) and not UiBlocked;

  if hot and IsMouseButtonPressed(MOUSE_BUTTON_LEFT) and MouseIn(tx - 8, y, tw + 16, 24) then
  begin
    ActiveSlider := id;
    EditStarted := True;
  end;
  if ActiveSlider = id then
    v := ClampParam(info, info.Min + (MouseX - tx) / tw * (info.Max - info.Min));

  if hot and (ActiveSlider < 0) then
  begin
    wheel := GetMouseWheelMove;
    if wheel <> 0 then
    begin
      if info.IsInt then step := 1 else step := (info.Max - info.Min) / 100;
      EditStarted := True;
      v := ClampParam(info, v + Sign(wheel) * step);
      EditFinished := True;
    end;
    if IsMouseButtonPressed(MOUSE_BUTTON_RIGHT) then
    begin
      EditStarted := True;
      v := defVal;
      EditFinished := True;
    end;
  end;

  if hot or (ActiveSlider = id) then
    DrawText(PChar(info.Name), x, y + 4, 16, C(255, 230, 120))
  else
    DrawText(PChar(info.Name), x, y + 4, 16, C(215, 215, 215));
  DrawRectangle(tx, y + 9, tw, 6, C(25, 25, 28));
  kx := tx + Round((v - info.Min) / (info.Max - info.Min) * tw);
  DrawRectangle(tx, y + 9, kx - tx, 6, C(190, 50, 35));
  if Abs(v - defVal) > 1e-4 then
    DrawRectangle(tx + Round((defVal - info.Min) / (info.Max - info.Min) * tw) - 1, y + 5, 2, 14, C(120, 120, 130));
  DrawRectangle(kx - 4, y + 3, 8, 18, C(235, 235, 235));
  if valueText <> '' then s := valueText else s := ParamToStr(info, v);
  DrawText(PChar(s), tx + tw + 10, y + 4, 16, C(235, 235, 235));
  Result := v <> old;
end;

procedure SectionTitle(const s: string; x, y: Integer);
begin
  DrawText(PChar(s), x, y, 20, C(230, 200, 60));
end;

end.
