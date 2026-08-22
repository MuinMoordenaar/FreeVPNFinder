#define MyAppName "Free VPN Finder"
#define MyAppVersion "1.2.0"
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
OutputBaseFilename=FreeVPNFinder-Setup
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

[UninstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\core"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\free_vpn_finder.exe"
Type: files; Name: "{app}\free_vpn_finder_updater.exe"

[Code]
var
  ActionPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  ActionPage := CreateInputOptionPage(
    wpSelectDir,
    'Choose action',
    '{#MyAppName}',
    'Select what you want to do:',
    True,
    False
  );
  ActionPage.Add('Install or update to the latest version');
  ActionPage.Add('Uninstall {#MyAppName}');
  ActionPage.SelectedValueIndex := 0;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Uninstaller: string;
  ErrorCode: Integer;
begin
  Result := True;
  if CurPageID = ActionPage.ID then
  begin
    if ActionPage.SelectedValueIndex = 1 then
    begin
      Uninstaller := ExpandConstant('{app}\unins000.exe');
      if FileExists(Uninstaller) then
      begin
        if MsgBox('Remove {#MyAppName} from this computer?', mbConfirmation, MB_YESNO) = IDYES then
        begin
          Exec(Uninstaller, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ErrorCode);
          WizardForm.Close;
        end;
      end
      else
        MsgBox('No existing installation was found.', mbInformation, MB_OK);
      Result := False;
    end;
  end;
end;
