#define MyAppName "Free VPN Finder"
#define MyAppVersion "1.1.9"
#define MyAppPublisher "Nezer"
#define MyAppExeName "free_vpn_finder.exe"

[Setup]
AppId={{B5C9CE87-6C13-43C2-8D86-7C4F1F3F4B0D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppCopyright=Free VPN Finder, made by Nezer
DefaultDirName={autopf}\FreeVPN Finder
DefaultGroupName={#MyAppName}
OutputDir=..\releases
OutputBaseFilename=FreeVPNFinder-Setup-v{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64
CloseApplications=yes
RestartApplications=no
UninstallDisplayName={#MyAppName}
Uninstallable=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\core"
Type: files; Name: "{app}\free_vpn_finder.exe"
Type: files; Name: "{app}\free_vpn_finder_updater.exe"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\app_icon.ico"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
