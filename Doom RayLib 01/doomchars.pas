unit doomchars;

{ Character definitions: monster stats and appearance, and player stats.
  Defaults are built in; characters.cfg (written by the character editor) overrides them. }

{$mode objfpc}{$H+}

interface

uses
  doomparams;

const
  CHAR_CONFIG_FILE = 'characters.cfg';

  NUM_MON = 2;
  MON_IMP = 0;
  MON_DEMON = 1;
  MonKeys: array[0..NUM_MON - 1] of string = ('imp', 'demon');
  MonNames: array[0..NUM_MON - 1] of string = ('Imp', 'Demon');

  // ---- monster parameters: stats
  MP_HP         = 0;
  MP_SPEED      = 1;
  MP_RANGED     = 2;
  MP_DMGMIN     = 3;
  MP_DMGMAX     = 4;
  MP_COOLDOWN   = 5;
  MP_RANGE      = 6;
  MP_PROJSPEED  = 7;
  MP_PAIN       = 8;
  MP_SIGHT      = 9;
  MP_DROP       = 10;
  MP_SCALE      = 11;
  // ---- monster parameters: look
  MP_FIRST_LOOK = 12;
  MP_BODYR      = 12;
  MP_BODYG      = 13;
  MP_BODYB      = 14;
  MP_EYER       = 15;
  MP_EYEG       = 16;
  MP_EYEB       = 17;
  MP_BODYW      = 18;
  MP_BODYH      = 19;
  MP_HEAD       = 20;
  MP_ARMS       = 21;
  MP_LEGS       = 22;
  MP_HORNS      = 23;
  MP_SPIKES     = 24;
  MP_MOUTH      = 25;
  NUM_MP        = 26;

  MpInfo: array[0..NUM_MP - 1] of TParamInfo = (
    (Key: 'health';     Name: 'Health';            Min: 1;    Max: 1000; IsInt: True),
    (Key: 'speed';      Name: 'Move speed';        Min: 0.2;  Max: 8;    IsInt: False),
    (Key: 'ranged';     Name: 'Attack type';       Min: 0;    Max: 1;    IsInt: True),
    (Key: 'damagemin';  Name: 'Damage min';        Min: 0;    Max: 100;  IsInt: True),
    (Key: 'damagemax';  Name: 'Damage max';        Min: 0;    Max: 100;  IsInt: True),
    (Key: 'cooldown';   Name: 'Attack delay (s)';  Min: 0.1;  Max: 6;    IsInt: False),
    (Key: 'range';      Name: 'Attack range';      Min: 0.6;  Max: 30;   IsInt: False),
    (Key: 'projspeed';  Name: 'Fireball speed';    Min: 1;    Max: 20;   IsInt: False),
    (Key: 'painchance'; Name: 'Pain chance';       Min: 0;    Max: 1;    IsInt: False),
    (Key: 'sight';      Name: 'Sight range';       Min: 2;    Max: 40;   IsInt: False),
    (Key: 'dropchance'; Name: 'Ammo drop chance';  Min: 0;    Max: 1;    IsInt: False),
    (Key: 'scale';      Name: 'Size in game';      Min: 0.4;  Max: 1.6;  IsInt: False),
    (Key: 'bodyr';      Name: 'Body red';          Min: 0;    Max: 255;  IsInt: True),
    (Key: 'bodyg';      Name: 'Body green';        Min: 0;    Max: 255;  IsInt: True),
    (Key: 'bodyb';      Name: 'Body blue';         Min: 0;    Max: 255;  IsInt: True),
    (Key: 'eyer';       Name: 'Eye red';           Min: 0;    Max: 255;  IsInt: True),
    (Key: 'eyeg';       Name: 'Eye green';         Min: 0;    Max: 255;  IsInt: True),
    (Key: 'eyeb';       Name: 'Eye blue';          Min: 0;    Max: 255;  IsInt: True),
    (Key: 'bodywidth';  Name: 'Body width';        Min: 6;    Max: 24;   IsInt: False),
    (Key: 'bodyheight'; Name: 'Body height';       Min: 6;    Max: 20;   IsInt: False),
    (Key: 'head';       Name: 'Head size';         Min: 0;    Max: 14;   IsInt: False),
    (Key: 'arms';       Name: 'Arm size';          Min: 0;    Max: 10;   IsInt: False),
    (Key: 'legs';       Name: 'Leg length';        Min: 4;    Max: 14;   IsInt: False),
    (Key: 'horns';      Name: 'Horn length';       Min: 0;    Max: 10;   IsInt: False),
    (Key: 'spikes';     Name: 'Bone spikes';       Min: 0;    Max: 1;    IsInt: True),
    (Key: 'mouth';      Name: 'Mouth size';        Min: 0;    Max: 14;   IsInt: False)
  );

  // ---- player parameters
  PP_HEALTH    = 0;
  PP_MAXHEALTH = 1;
  PP_AMMO      = 2;
  PP_MAXAMMO   = 3;
  PP_SPEED     = 4;
  PP_RUN       = 5;
  PP_PELLETS   = 6;
  PP_PDMGMIN   = 7;
  PP_PDMGMAX   = 8;
  PP_SPREAD    = 9;
  PP_FIRECD    = 10;
  PP_MEDKIT    = 11;
  PP_AMMOBOX   = 12;
  PP_MOUSE     = 13;
  NUM_PP       = 14;

  PpInfo: array[0..NUM_PP - 1] of TParamInfo = (
    (Key: 'health';      Name: 'Start health';      Min: 1;      Max: 200;   IsInt: True),
    (Key: 'maxhealth';   Name: 'Max health';        Min: 1;      Max: 200;   IsInt: True),
    (Key: 'ammo';        Name: 'Start shells';      Min: 0;      Max: 200;   IsInt: True),
    (Key: 'maxammo';     Name: 'Max shells';        Min: 1;      Max: 200;   IsInt: True),
    (Key: 'speed';       Name: 'Walk speed';        Min: 1;      Max: 8;     IsInt: False),
    (Key: 'run';         Name: 'Run multiplier';    Min: 1;      Max: 3;     IsInt: False),
    (Key: 'pellets';     Name: 'Pellets per shot';  Min: 1;      Max: 20;    IsInt: True),
    (Key: 'pelletmin';   Name: 'Pellet damage min'; Min: 1;      Max: 50;    IsInt: True),
    (Key: 'pelletmax';   Name: 'Pellet damage max'; Min: 1;      Max: 50;    IsInt: True),
    (Key: 'spread';      Name: 'Spread (radians)';  Min: 0;      Max: 0.5;   IsInt: False),
    (Key: 'firedelay';   Name: 'Fire delay (s)';    Min: 0.1;    Max: 2;     IsInt: False),
    (Key: 'medikit';     Name: 'Medikit heals';     Min: 1;      Max: 100;   IsInt: True),
    (Key: 'shellbox';    Name: 'Shells per box';    Min: 1;      Max: 50;    IsInt: True),
    (Key: 'mouse';       Name: 'Mouse sensitivity'; Min: 0.0005; Max: 0.006; IsInt: False)
  );

type
  TMonsterDef = array[0..NUM_MP - 1] of Single;
  TPlayerDef = array[0..NUM_PP - 1] of Single;

const
  DefaultMonsters: array[0..NUM_MON - 1] of TMonsterDef = (
    // hp  spd  rng dmin dmax cd   range proj pain  sight drop scale  body r,g,b    eye r,g,b    bw  bh  head arm leg horn spk mouth
    (60,  1.5, 1,  10,  21,  1.5, 16,   6.5, 0.45, 20,   0.35, 0.95, 140, 88, 52,  255, 70, 0,  13, 15, 9,   5,  11, 0,   1,  4),
    (150, 3.0, 0,  8,   17,  0.6, 1.1,  6.5, 0.25, 20,   0,    0.9,  215, 105, 130, 255, 230, 0, 20, 15, 0,   5,  11, 4,   0,  13)
  );
  DefaultPlayer: TPlayerDef =
    // hp max ammo max  spd  run pel dmin dmax spread cd   med box mouse
    (100, 100, 20, 50, 3.2, 1.7, 7, 5,   15,  0.11,  0.9, 25, 8,  0.0022);

var
  MonDefs: array[0..NUM_MON - 1] of TMonsterDef;
  PlayerDef: TPlayerDef;

procedure ResetCharacters;
function LoadCharConfig(const fileName: string): Boolean;
function SaveCharConfig(const fileName: string): Boolean;

implementation

uses
  SysUtils, IniFiles;

procedure ResetCharacters;
begin
  MonDefs := DefaultMonsters;
  PlayerDef := DefaultPlayer;
end;

function LoadCharConfig(const fileName: string): Boolean;
var
  ini: TMemIniFile;
  i: Integer;
begin
  Result := False;
  if not FileExists(fileName) then Exit;
  ini := TMemIniFile.Create(fileName);
  try
    for i := 0 to NUM_MON - 1 do
      ReadParamSection(ini, MonKeys[i], MpInfo, MonDefs[i]);
    ReadParamSection(ini, 'player', PpInfo, PlayerDef);
  finally
    ini.Free;
  end;
  Result := True;
end;

function SaveCharConfig(const fileName: string): Boolean;
var
  ini: TMemIniFile;
  i: Integer;
begin
  Result := False;
  try
    ini := TMemIniFile.Create(fileName);
    try
      ini.Clear;
      for i := 0 to NUM_MON - 1 do
        WriteParamSection(ini, MonKeys[i], MpInfo, MonDefs[i]);
      WriteParamSection(ini, 'player', PpInfo, PlayerDef);
      ini.UpdateFile;
      Result := True;
    finally
      ini.Free;
    end;
  except
    Result := False;
  end;
end;

initialization
  ResetCharacters;

end.
