unit doomsound;

{ Parametric sound effect synthesizer. Every game sound is described by the same set of
  parameters (oscillator, noise, thump, envelope, tremolo, arpeggio). Defaults are built in;
  sounds.cfg (written by the sound editor) overrides them. }

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, raylib, doomparams;

const
  RATE = 22050;
  SFX_CONFIG_FILE = 'sounds.cfg';

  NUM_SFX = 13;
  SFX_SHOTGUN     = 0;
  SFX_IMPSIGHT    = 1;
  SFX_DEMONSIGHT  = 2;
  SFX_FIREBALL    = 3;
  SFX_EXPLODE     = 4;
  SFX_PLAYERPAIN  = 5;
  SFX_PLAYERDEATH = 6;
  SFX_MONPAIN     = 7;
  SFX_MONDEATH    = 8;
  SFX_PICKUP      = 9;
  SFX_DOOR        = 10;
  SFX_BITE        = 11;
  SFX_SWITCH      = 12;

  SfxKeys: array[0..NUM_SFX - 1] of string = (
    'shotgun', 'impsight', 'demonsight', 'fireball', 'explode', 'playerpain', 'playerdeath',
    'monpain', 'mondeath', 'pickup', 'door', 'bite', 'switch');
  SfxNames: array[0..NUM_SFX - 1] of string = (
    'Shotgun blast', 'Imp sight', 'Demon sight', 'Fireball launch', 'Explosion', 'Player pain',
    'Player death', 'Monster pain', 'Monster death', 'Item pickup', 'Door', 'Demon bite', 'Exit switch');

  NUM_SP = 22;
  SP_DUR        = 0;
  SP_WAVE       = 1;
  SP_FREQSTART  = 2;
  SP_FREQEND    = 3;
  SP_VIBRATE    = 4;
  SP_VIBDEPTH   = 5;
  SP_TONEVOL    = 6;
  SP_NOISEVOL   = 7;
  SP_NOISESTART = 8;
  SP_NOISEEND   = 9;
  SP_THUMPFREQ  = 10;
  SP_THUMPVOL   = 11;
  SP_THUMPDECAY = 12;
  SP_ATTACK     = 13;
  SP_RELEASE    = 14;
  SP_DECAY      = 15;
  SP_TREMRATE   = 16;
  SP_TREMDEPTH  = 17;
  SP_ARPTIME    = 18;
  SP_ARPSEMIS   = 19;
  SP_ARPNOTES   = 20;
  SP_VOLUME     = 21;

  WaveNames: array[0..4] of string = ('Off', 'Sine', 'Square', 'Saw', 'Triangle');

  SpInfo: array[0..NUM_SP - 1] of TParamInfo = (
    (Key: 'duration';   Name: 'Duration (s)';      Min: 0.05; Max: 2.0;  IsInt: False),
    (Key: 'wave';       Name: 'Waveform';          Min: 0;    Max: 4;    IsInt: True),
    (Key: 'freqstart';  Name: 'Pitch start (Hz)';  Min: 20;   Max: 2000; IsInt: False),
    (Key: 'freqend';    Name: 'Pitch end (Hz)';    Min: 20;   Max: 2000; IsInt: False),
    (Key: 'vibrate';    Name: 'Vibrato rate';      Min: 0;    Max: 60;   IsInt: False),
    (Key: 'vibdepth';   Name: 'Vibrato depth';     Min: 0;    Max: 0.5;  IsInt: False),
    (Key: 'tonevol';    Name: 'Tone volume';       Min: 0;    Max: 1;    IsInt: False),
    (Key: 'noisevol';   Name: 'Noise volume';      Min: 0;    Max: 1;    IsInt: False),
    (Key: 'noisestart'; Name: 'Noise bright start'; Min: 0.01; Max: 1;   IsInt: False),
    (Key: 'noiseend';   Name: 'Noise bright end';  Min: 0.01; Max: 1;    IsInt: False),
    (Key: 'thumpfreq';  Name: 'Thump (Hz)';        Min: 20;   Max: 200;  IsInt: False),
    (Key: 'thumpvol';   Name: 'Thump volume';      Min: 0;    Max: 1;    IsInt: False),
    (Key: 'thumpdecay'; Name: 'Thump decay';       Min: 0;    Max: 40;   IsInt: False),
    (Key: 'attack';     Name: 'Attack (s)';        Min: 0;    Max: 0.5;  IsInt: False),
    (Key: 'release';    Name: 'Release (s)';       Min: 0;    Max: 1;    IsInt: False),
    (Key: 'decay';      Name: 'Decay';             Min: 0;    Max: 20;   IsInt: False),
    (Key: 'tremrate';   Name: 'Tremolo rate';      Min: 0;    Max: 100;  IsInt: False),
    (Key: 'tremdepth';  Name: 'Tremolo depth';     Min: 0;    Max: 1;    IsInt: False),
    (Key: 'arptime';    Name: 'Arp step (s)';      Min: 0;    Max: 0.3;  IsInt: False),
    (Key: 'arpsemis';   Name: 'Arp semitones';     Min: -12;  Max: 12;   IsInt: True),
    (Key: 'arpnotes';   Name: 'Arp notes';         Min: 1;    Max: 8;    IsInt: True),
    (Key: 'volume';     Name: 'Volume';            Min: 0;    Max: 2;    IsInt: False)
  );

type
  TSfxParams = array[0..NUM_SP - 1] of Single;
  TSamples = array of Single;
  TByteArray = array of Byte;

const
  //            dur  wave  f0      f1     vibR vibD tone  noise nS    nE    thF  thV  thD  att    rel   dec  trR trD  arpT arpS arpN vol
  DefaultSfx: array[0..NUM_SFX - 1] of TSfxParams = (
    (0.55, 0, 100,    100,   0,  0,    0,    1,    0.64, 0.04, 55,  0.6, 14,  0.002, 0.05, 6.5, 0,  0,   0,    0,   1,   1.5),
    (0.6,  3, 190,    90,    8,  0.06, 0.6,  0.35, 1,    1,    50,  0,   0,   0.2,   0.3,  0,   11, 0.5, 0,    0,   1,   1.0),
    (0.75, 3, 95,     55,    8,  0.08, 0.6,  0.5,  1,    1,    50,  0,   0,   0.25,  0.35, 0,   11, 0.5, 0,    0,   1,   1.0),
    (0.4,  0, 100,    100,   0,  0,    0,    1,    0.08, 0.2,  50,  0,   0,   0.18,  0.2,  0,   0,  0,   0,    0,   1,   1.3),
    (0.6,  0, 100,    100,   0,  0,    0,    1,    0.5,  0.04, 45,  0.6, 0,   0.002, 0.1,  6,   0,  0,   0,    0,   1,   1.4),
    (0.3,  2, 210,    120,   0,  0,    0.5,  0.15, 1,    1,    50,  0,   0,   0.005, 0.05, 6,   0,  0,   0,    0,   1,   1.0),
    (1.2,  3, 230,    40,    8,  0.06, 0.6,  0.3,  1,    1,    50,  0,   0,   0.3,   0.5,  0,   11, 0.5, 0,    0,   1,   1.0),
    (0.2,  2, 320,    200,   0,  0,    0.5,  0.15, 1,    1,    50,  0,   0,   0.005, 0.05, 6,   0,  0,   0,    0,   1,   1.0),
    (0.8,  3, 260,    50,    8,  0.06, 0.6,  0.45, 1,    1,    50,  0,   0,   0.2,   0.4,  0,   11, 0.5, 0,    0,   1,   1.0),
    (0.16, 1, 880,    880,   0,  0,    0.5,  0,    1,    1,    50,  0,   0,   0.002, 0.16, 0,   0,  0,   0.07, 7,   2,   1.0),
    (0.8,  0, 100,    100,   0,  0,    0,    1,    0.06, 0.06, 70,  0.3, 0,   0.05,  0.17, 0,   28, 0.4, 0,    0,   1,   1.3),
    (0.2,  0, 100,    100,   0,  0,    0,    0.9,  0.7,  0.2,  120, 0.6, 0,   0.002, 0.05, 18,  0,  0,   0,    0,   1,   1.2),
    (0.7,  1, 523.25, 523.25, 0, 0,    0.45, 0,    1,    1,    50,  0,   0,   0.002, 0.1,  6,   0,  0,   0.12, 4,   4,   1.0)
  );

var
  SfxParams: array[0..NUM_SFX - 1] of TSfxParams;
  Sfx: array[0..NUM_SFX - 1] of TSound;

procedure ResetAllSfx;
function Synthesize(const p: TSfxParams): TSamples;
function WavBytes(const s: TSamples): TByteArray;
function SoundFromSamples(const s: TSamples): TSound;
function LoadSfxConfig(const fileName: string): Boolean;
function SaveSfxConfig(const fileName: string): Boolean;
procedure LoadSounds;            // synthesizes Sfx[] from SfxParams[] (needs the audio device)
procedure ReloadSound(id: Integer);
procedure UnloadSounds;
procedure PlaySfx(const s: TSound; volume: Single = 1.0; pitch: Single = 1.0);

implementation

uses
  Math, IniFiles;

var
  SoundsLoaded: Boolean = False;

procedure ResetAllSfx;
begin
  SfxParams := DefaultSfx;
end;

function Synthesize(const p: TSfxParams): TSamples;
var
  i, n, step, wave: Integer;
  t, u, dur, f, ph, osc, k, lp, noise, thump, env, trem, lt, fr, v: Single;
  seed: Cardinal;
begin
  dur := p[SP_DUR];
  n := Max(1, Round(dur * RATE));
  SetLength(Result, n);
  wave := Round(p[SP_WAVE]);
  ph := 0;
  lp := 0;
  seed := 12345;   // fixed seed: the same parameters always give the same sound
  for i := 0 to n - 1 do
  begin
    t := i / RATE;
    u := t / dur;

    // pitch: linear slide, optional arpeggio steps and vibrato
    f := p[SP_FREQSTART] + (p[SP_FREQEND] - p[SP_FREQSTART]) * u;
    step := 0;
    lt := t;
    if p[SP_ARPTIME] > 0.001 then
    begin
      step := Min(Trunc(t / p[SP_ARPTIME]), Round(p[SP_ARPNOTES]) - 1);
      f := f * Power(2, p[SP_ARPSEMIS] * step / 12);
      lt := t - step * p[SP_ARPTIME];    // decay restarts on every arpeggio note
    end;
    if p[SP_VIBDEPTH] > 0 then
      f := f * (1 + p[SP_VIBDEPTH] * Sin(2 * Pi * p[SP_VIBRATE] * t));
    ph := ph + f / RATE;
    fr := Frac(ph);
    case wave of
      1: osc := Sin(2 * Pi * fr);
      2: if fr < 0.5 then osc := 0.6 else osc := -0.6;
      3: osc := (2 * fr - 1) * 0.75;
      4: osc := 4 * Abs(fr - 0.5) - 1;
    else
      osc := 0;
    end;

    // low-passed noise; brightness = filter coefficient, loudness normalised
    seed := seed * 1664525 + 1013904223;
    k := p[SP_NOISESTART] + (p[SP_NOISEEND] - p[SP_NOISESTART]) * u;
    lp := lp + (((seed shr 8) / 8388608.0 - 1) - lp) * k;
    noise := lp / Sqrt(k / (2 - k)) * 0.55;

    thump := Sin(2 * Pi * p[SP_THUMPFREQ] * t) * Exp(-t * p[SP_THUMPDECAY]);

    env := 1;
    if p[SP_ATTACK] > 0 then env := Min(1, t / p[SP_ATTACK]);
    if p[SP_RELEASE] > 0 then env := env * Min(1, (dur - t) / p[SP_RELEASE]);
    env := env * Exp(-lt * p[SP_DECAY]);
    trem := 1 - p[SP_TREMDEPTH] * (0.5 + 0.5 * Sin(2 * Pi * p[SP_TREMRATE] * t));

    v := (osc * p[SP_TONEVOL] + noise * p[SP_NOISEVOL] + thump * p[SP_THUMPVOL]) * env * trem * p[SP_VOLUME];
    Result[i] := EnsureRange(v, -1.0, 1.0);
  end;
end;

function WavBytes(const s: TSamples): TByteArray;
var
  n, i, dataSize: Integer;

  procedure Put16(ofs: Integer; val: Word);
  begin
    Result[ofs] := val and $FF;
    Result[ofs + 1] := val shr 8;
  end;

  procedure Put32(ofs: Integer; val: Cardinal);
  begin
    Result[ofs] := val and $FF;
    Result[ofs + 1] := (val shr 8) and $FF;
    Result[ofs + 2] := (val shr 16) and $FF;
    Result[ofs + 3] := val shr 24;
  end;

  procedure PutTag(ofs: Integer; const tag: string);
  var
    k: Integer;
  begin
    for k := 1 to 4 do
      Result[ofs + k - 1] := Ord(tag[k]);
  end;

begin
  n := Length(s);
  dataSize := n * 2;
  SetLength(Result, 44 + dataSize);
  PutTag(0, 'RIFF');
  Put32(4, 36 + dataSize);
  PutTag(8, 'WAVE');
  PutTag(12, 'fmt ');
  Put32(16, 16);
  Put16(20, 1);          // PCM
  Put16(22, 1);          // mono
  Put32(24, RATE);
  Put32(28, RATE * 2);
  Put16(32, 2);
  Put16(34, 16);
  PutTag(36, 'data');
  Put32(40, dataSize);
  for i := 0 to n - 1 do
    Put16(44 + i * 2, Word(SmallInt(Round(EnsureRange(s[i], -1.0, 1.0) * 30000))));
end;

function SoundFromSamples(const s: TSamples): TSound;
var
  data: TByteArray;
  w: TWave;
begin
  data := WavBytes(s);
  w := LoadWaveFromMemory('.wav', @data[0], Length(data));
  Result := LoadSoundFromWave(w);
  UnloadWave(w);
end;

function LoadSfxConfig(const fileName: string): Boolean;
var
  ini: TMemIniFile;
  i: Integer;
begin
  Result := False;
  if not FileExists(fileName) then Exit;
  ini := TMemIniFile.Create(fileName);
  try
    for i := 0 to NUM_SFX - 1 do
      ReadParamSection(ini, SfxKeys[i], SpInfo, SfxParams[i]);
  finally
    ini.Free;
  end;
  Result := True;
end;

function SaveSfxConfig(const fileName: string): Boolean;
var
  ini: TMemIniFile;
  i: Integer;
begin
  Result := False;
  try
    ini := TMemIniFile.Create(fileName);
    try
      ini.Clear;
      for i := 0 to NUM_SFX - 1 do
        WriteParamSection(ini, SfxKeys[i], SpInfo, SfxParams[i]);
      ini.UpdateFile;
      Result := True;
    finally
      ini.Free;
    end;
  except
    Result := False;
  end;
end;

procedure LoadSounds;
var
  i: Integer;
begin
  if not IsAudioDeviceReady then Exit;
  for i := 0 to NUM_SFX - 1 do
    Sfx[i] := SoundFromSamples(Synthesize(SfxParams[i]));
  SoundsLoaded := True;
end;

procedure ReloadSound(id: Integer);
begin
  if not SoundsLoaded then Exit;
  StopSound(Sfx[id]);
  UnloadSound(Sfx[id]);
  Sfx[id] := SoundFromSamples(Synthesize(SfxParams[id]));
end;

procedure UnloadSounds;
var
  i: Integer;
begin
  if not SoundsLoaded then Exit;
  for i := 0 to NUM_SFX - 1 do
    UnloadSound(Sfx[i]);
  SoundsLoaded := False;
end;

procedure PlaySfx(const s: TSound; volume: Single; pitch: Single);
begin
  if not SoundsLoaded then Exit;
  SetSoundVolume(s, volume);
  SetSoundPitch(s, pitch);
  PlaySound(s);
end;

initialization
  ResetAllSfx;

end.
