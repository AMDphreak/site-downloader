[Setup]
AppId={{D3708D5B-4C04-4B7E-97B5-2C5C36EBC6A1}}
AppName=Site Downloader
AppVersion=1.0.1
AppPublisher=AMDphreak
AppPublisherURL=https://github.com/AMDphreak/site-downloader
AppSupportURL=https://github.com/AMDphreak/site-downloader/issues
AppUpdatesURL=https://github.com/AMDphreak/site-downloader/releases
DefaultDirName={autopf}\Site Downloader
DefaultGroupName=Site Downloader
AllowNoIcons=yes
OutputDir=..\Output
OutputBaseFilename=site-downloader-setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\apps\cli\site-downloader-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\apps\gui\site-downloader-gui.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Site Downloader GUI"; Filename: "{app}\site-downloader-gui.exe"
Name: "{group}\Site Downloader CLI"; Filename: "{app}\site-downloader-cli.exe"
Name: "{commondesktop}\Site Downloader GUI"; Filename: "{app}\site-downloader-gui.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\site-downloader-gui.exe"; Description: "{cm:LaunchProgram,Site Downloader}"; Flags: nowait postinstall skipfsentry
