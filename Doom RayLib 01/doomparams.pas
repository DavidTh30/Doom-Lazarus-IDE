unit doomparams;

{ Named numeric parameters with ranges, and reading/writing them in INI-style config files.
  Used for the sound effect definitions (sounds.cfg) and characters (characters.cfg). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, IniFiles;

type
  TParamInfo = record
    Key, Name: string;
    Min, Max: Single;
    IsInt: Boolean;
  end;

var
  CfgFormat: TFormatSettings;   // always '.' as decimal separator, whatever the locale

function ClampParam(const info: TParamInfo; v: Single): Single;
function ParamToStr(const info: TParamInfo; v: Single): string;
procedure ReadParamSection(ini: TCustomIniFile; const section: string;
  const info: array of TParamInfo; var values: array of Single);
procedure WriteParamSection(ini: TCustomIniFile; const section: string;
  const info: array of TParamInfo; const values: array of Single);
// Relative names are resolved against the folder of the running executable
function ExePath(const fileName: string): string;

implementation

uses
  Math;

function ClampParam(const info: TParamInfo; v: Single): Single;
begin
  if IsNan(v) then v := info.Min;
  Result := EnsureRange(v, info.Min, info.Max);
  if info.IsInt then Result := Round(Result);
end;

function ParamToStr(const info: TParamInfo; v: Single): string;
begin
  if info.IsInt then
    Result := IntToStr(Round(v))
  else
    Result := FloatToStrF(v, ffGeneral, 5, 0, CfgFormat);
end;

procedure ReadParamSection(ini: TCustomIniFile; const section: string;
  const info: array of TParamInfo; var values: array of Single);
var
  i: Integer;
  s: string;
begin
  for i := 0 to High(info) do
  begin
    s := Trim(ini.ReadString(section, info[i].Key, ''));
    if s <> '' then
      values[i] := ClampParam(info[i], StrToFloatDef(s, values[i], CfgFormat));
  end;
end;

procedure WriteParamSection(ini: TCustomIniFile; const section: string;
  const info: array of TParamInfo; const values: array of Single);
var
  i: Integer;
begin
  for i := 0 to High(info) do
    ini.WriteString(section, info[i].Key, ParamToStr(info[i], values[i]));
end;

function ExePath(const fileName: string): string;
begin
  if (ExtractFileDrive(fileName) <> '') or ((fileName <> '') and (fileName[1] in ['\', '/'])) then
    Result := ExpandFileName(fileName)
  else
    Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + fileName);
end;

initialization
  CfgFormat := DefaultFormatSettings;
  CfgFormat.DecimalSeparator := '.';

end.
