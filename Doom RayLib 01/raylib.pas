unit raylib;

{ Minimal Free Pascal bindings for the parts of raylib used by RayDoom.
  Links dynamically against raylib.dll (x64), which must sit next to the exe. }

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

const
  RaylibLib = 'raylib.dll';

  // Config flags
  FLAG_VSYNC_HINT = $00000040;

  // Trace log levels
  LOG_WARNING = 4;

  // Keyboard keys
  KEY_NULL          = 0;
  KEY_SPACE         = 32;
  KEY_A             = 65;
  KEY_D             = 68;
  KEY_E             = 69;
  KEY_M             = 77;
  KEY_Q             = 81;
  KEY_R             = 82;
  KEY_S             = 83;
  KEY_W             = 87;
  KEY_ESCAPE        = 256;
  KEY_ENTER         = 257;
  KEY_TAB           = 258;
  KEY_RIGHT         = 262;
  KEY_LEFT          = 263;
  KEY_DOWN          = 264;
  KEY_UP            = 265;
  KEY_LEFT_SHIFT    = 340;
  KEY_LEFT_CONTROL  = 341;
  KEY_RIGHT_CONTROL = 345;

  KEY_MINUS         = 45;
  KEY_ZERO          = 48;
  KEY_ONE           = 49;
  KEY_EQUAL         = 61;
  KEY_B             = 66;
  KEY_C             = 67;
  KEY_F             = 70;
  KEY_G             = 71;
  KEY_I             = 73;
  KEY_N             = 78;
  KEY_O             = 79;
  KEY_T             = 84;
  KEY_V             = 86;
  KEY_Y             = 89;
  KEY_Z             = 90;
  KEY_GRAVE         = 96;
  KEY_BACKSPACE     = 259;
  KEY_F5            = 294;

  // Mouse buttons
  MOUSE_BUTTON_LEFT   = 0;
  MOUSE_BUTTON_RIGHT  = 1;
  MOUSE_BUTTON_MIDDLE = 2;

type
  TColor = record
    r, g, b, a: Byte;
  end;

  TVector2 = record
    x, y: Single;
  end;

  TRectangle = record
    x, y, width, height: Single;
  end;

  TImage = record
    data: Pointer;
    width, height, mipmaps, format: Integer;
  end;

  TTexture2D = record
    id: Cardinal;
    width, height, mipmaps, format: Integer;
  end;

  TRenderTexture2D = record
    id: Cardinal;
    texture: TTexture2D;
    depth: TTexture2D;
  end;

  TWave = record
    frameCount, sampleRate, sampleSize, channels: Cardinal;
    data: Pointer;
  end;

  TAudioStream = record
    buffer, processor: Pointer;
    sampleRate, sampleSize, channels: Cardinal;
  end;

  TSound = record
    stream: TAudioStream;
    frameCount: Cardinal;
  end;

const
  WHITE: TColor = (r: 255; g: 255; b: 255; a: 255);
  BLACK: TColor = (r: 0; g: 0; b: 0; a: 255);

// Window / timing
procedure InitWindow(width, height: Integer; title: PChar); cdecl; external RaylibLib;
procedure CloseWindow; cdecl; external RaylibLib;
function WindowShouldClose: Boolean; cdecl; external RaylibLib;
procedure SetConfigFlags(flags: Cardinal); cdecl; external RaylibLib;
procedure SetTraceLogLevel(logLevel: Integer); cdecl; external RaylibLib;
procedure SetTargetFPS(fps: Integer); cdecl; external RaylibLib;
function GetFrameTime: Single; cdecl; external RaylibLib;
function GetTime: Double; cdecl; external RaylibLib;
procedure SetExitKey(key: Integer); cdecl; external RaylibLib;
procedure TakeScreenshot(fileName: PChar); cdecl; external RaylibLib;

// Input
function IsKeyDown(key: Integer): Boolean; cdecl; external RaylibLib;
function IsKeyPressed(key: Integer): Boolean; cdecl; external RaylibLib;
function IsMouseButtonDown(button: Integer): Boolean; cdecl; external RaylibLib;
function IsMouseButtonPressed(button: Integer): Boolean; cdecl; external RaylibLib;
function GetMouseDelta: TVector2; cdecl; external RaylibLib;
function GetMousePosition: TVector2; cdecl; external RaylibLib;
function GetMouseWheelMove: Single; cdecl; external RaylibLib;
function IsMouseButtonReleased(button: Integer): Boolean; cdecl; external RaylibLib;
function IsKeyPressedRepeat(key: Integer): Boolean; cdecl; external RaylibLib;
function GetCharPressed: Integer; cdecl; external RaylibLib;
procedure SetWindowTitle(title: PChar); cdecl; external RaylibLib;
procedure DisableCursor; cdecl; external RaylibLib;
procedure EnableCursor; cdecl; external RaylibLib;

// Drawing
procedure BeginDrawing; cdecl; external RaylibLib;
procedure EndDrawing; cdecl; external RaylibLib;
procedure ClearBackground(color: TColor); cdecl; external RaylibLib;
procedure BeginTextureMode(target: TRenderTexture2D); cdecl; external RaylibLib;
procedure EndTextureMode; cdecl; external RaylibLib;
procedure DrawRectangle(posX, posY, width, height: Integer; color: TColor); cdecl; external RaylibLib;
procedure DrawRectangleLines(posX, posY, width, height: Integer; color: TColor); cdecl; external RaylibLib;
procedure DrawTriangle(v1, v2, v3: TVector2; color: TColor); cdecl; external RaylibLib;
procedure DrawCircle(centerX, centerY: Integer; radius: Single; color: TColor); cdecl; external RaylibLib;
procedure DrawEllipse(centerX, centerY: Integer; radiusH, radiusV: Single; color: TColor); cdecl; external RaylibLib;
procedure DrawLine(startPosX, startPosY, endPosX, endPosY: Integer; color: TColor); cdecl; external RaylibLib;
procedure DrawText(text: PChar; posX, posY, fontSize: Integer; color: TColor); cdecl; external RaylibLib;
function MeasureText(text: PChar; fontSize: Integer): Integer; cdecl; external RaylibLib;

// Textures
function GenImageColor(width, height: Integer; color: TColor): TImage; cdecl; external RaylibLib;
procedure UnloadImage(image: TImage); cdecl; external RaylibLib;
function LoadTextureFromImage(image: TImage): TTexture2D; cdecl; external RaylibLib;
procedure UnloadTexture(texture: TTexture2D); cdecl; external RaylibLib;
function LoadRenderTexture(width, height: Integer): TRenderTexture2D; cdecl; external RaylibLib;
procedure UnloadRenderTexture(target: TRenderTexture2D); cdecl; external RaylibLib;
procedure UpdateTexture(texture: TTexture2D; pixels: Pointer); cdecl; external RaylibLib;
procedure DrawTexture(texture: TTexture2D; posX, posY: Integer; tint: TColor); cdecl; external RaylibLib;
procedure DrawTexturePro(texture: TTexture2D; source, dest: TRectangle; origin: TVector2;
  rotation: Single; tint: TColor); cdecl; external RaylibLib;

// Audio
procedure InitAudioDevice; cdecl; external RaylibLib;
procedure CloseAudioDevice; cdecl; external RaylibLib;
function IsAudioDeviceReady: Boolean; cdecl; external RaylibLib;
function LoadWaveFromMemory(fileType: PChar; fileData: Pointer; dataSize: Integer): TWave; cdecl; external RaylibLib;
procedure UnloadWave(wave: TWave); cdecl; external RaylibLib;
function LoadSoundFromWave(wave: TWave): TSound; cdecl; external RaylibLib;
procedure UnloadSound(sound: TSound); cdecl; external RaylibLib;
procedure PlaySound(sound: TSound); cdecl; external RaylibLib;
procedure StopSound(sound: TSound); cdecl; external RaylibLib;
function IsSoundPlaying(sound: TSound): Boolean; cdecl; external RaylibLib;
procedure SetSoundVolume(sound: TSound; volume: Single); cdecl; external RaylibLib;
procedure SetSoundPitch(sound: TSound; pitch: Single); cdecl; external RaylibLib;

// Small Pascal helpers
function ColorRGBA(r, g, b: Integer; a: Integer = 255): TColor;
function Vec2(x, y: Single): TVector2;
function Rect(x, y, w, h: Single): TRectangle;

implementation

function ClampByte(v: Integer): Byte; inline;
begin
  if v < 0 then Result := 0
  else if v > 255 then Result := 255
  else Result := v;
end;

function ColorRGBA(r, g, b: Integer; a: Integer): TColor;
begin
  Result.r := ClampByte(r);
  Result.g := ClampByte(g);
  Result.b := ClampByte(b);
  Result.a := ClampByte(a);
end;

function Vec2(x, y: Single): TVector2;
begin
  Result.x := x;
  Result.y := y;
end;

function Rect(x, y, w, h: Single): TRectangle;
begin
  Result.x := x;
  Result.y := y;
  Result.width := w;
  Result.height := h;
end;

end.
