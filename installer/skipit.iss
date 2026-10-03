; Установщик SkipIt (Inno Setup 6/7).
; Собирается скриптом tools\build.ps1: версия передаётся через /DAppVersion=... (из тега релиза).
;   ISCC.exe /DAppVersion=1.0.7 installer\skipit.iss

#ifndef AppVersion
  #define AppVersion "1.0.7"
#endif
#define AppName "SkipIt"
#define AppExe "SkipIt.exe"
#define Release "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6E2D5B1A-7C3F-4B8E-9A41-5F0C2D8E3B17}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=SkipIt
AppPublisherURL=https://github.com/getskipit/skipit
AppSupportURL=https://github.com/getskipit/skipit/issues
AppUpdatesURL=https://github.com/getskipit/skipit/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Режим TUN всё равно требует прав администратора, поэтому ставим в Program Files.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\installer
; Начало «SkipIt-Setup» должно сохраняться: по нему установленные версии находят установщик в релизе.
OutputBaseFilename=SkipIt-Setup-Windows-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Лицензия показывается на отдельном шаге мастера установки.
LicenseFile=..\LICENSE
; Если программа всё же запущена — закрыть её перед заменой файлов.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\core\skipit-xray.exe"; DestDir: "{app}\core"; Flags: ignoreversion
Source: "..\core\skipit-sing-box.exe"; DestDir: "{app}\core"; Flags: ignoreversion
; Драйвер адаптера для режима «TUN на ядре Xray» (из архива Xray-core).
Source: "..\core\wintun.dll"; DestDir: "{app}\core"; Flags: ignoreversion
; Лицензии: своя и вложенных ядер (MPL-2.0 и GPL-3.0 требуют прикладывать их текст и ссылки на исходники).
Source: "..\core\LICENSE-Xray.txt"; DestDir: "{app}\core"; Flags: ignoreversion
Source: "..\core\LICENSE-sing-box.txt"; DestDir: "{app}\core"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\NOTICE"; DestDir: "{app}"; DestName: "NOTICE.txt"; Flags: ignoreversion
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; DestName: "THIRD_PARTY_NOTICES.txt"; Flags: ignoreversion

[InstallDelete]
; Ядра из версии 1.0.0 назывались xray.exe и sing-box.exe — убираем их при обновлении.
Type: files; Name: "{app}\core\xray.exe"
Type: files; Name: "{app}\core\sing-box.exe"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Registry]
; Эти ключи создаёт сама программа (автозапуск, ссылки skipit://, положение окна) — убираем при удалении.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "SkipIt"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\skipit"; ValueType: none; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\SkipIt"; ValueType: none; Flags: uninsdeletekey

[UninstallDelete]
Type: filesandordirs; Name: "{app}\core"
; Папка, куда программа скачивает установщик обновления.
Type: filesandordirs; Name: "{app}\update"

[Code]
// Перед установкой и удалением просим запущенный SkipIt корректно выйти: он отключит VPN
// и вернёт системный прокси. Просто «убить» процесс нельзя — у пользователя пропал бы интернет.
procedure QuitRunningApp();
var
  Code: Integer;
begin
  if FileExists(ExpandConstant('{app}\{#AppExe}')) then
  begin
    Exec(ExpandConstant('{app}\{#AppExe}'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Sleep(2500);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  QuitRunningApp();
  Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    QuitRunningApp();
end;
