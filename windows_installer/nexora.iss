; مُثبّت ويندوز الحقيقي لتطبيق "مدير الحسابات" (Nexora).
; يُترجم بسكربت Inno Setup 6 (ISCC.exe) على خادم بناء ويندوز في CI.
; يُنتج ملف NexoraSetup.exe: يُثبّت في Program Files، ينشئ اختصارات
; قائمة ابدأ وسطح المكتب، وله برنامج إلغاء تثبيت — ويعمل رغم تحذير SmartScreen.

#define MyAppName "مدير الحسابات"
; يُستبدل رقم الإصدار تلقائياً في CI من pubspec.yaml قبل الترجمة.
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Nexora"
#define MyAppExeName "nexora_app.exe"

[Setup]
AppId={{F4D92C7E-3B6A-4E1A-9C8F-2D7B5E0A1F34}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Nexora
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=NexoraSetup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
AppCopyright=Nexora
; عند التحديث فوق نسخة مثبتة: أغلق التطبيق الجاري تلقائياً وأعد تشغيله.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:";

[Files]
; محتوى مجلد staging (نسخة Release الكاملة) يُثبَّت كاملًا.
Source: "staging\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; (دفعة 52) تسجيل قاعدتي جدار الحماية (دخول/خروج) أثناء التثبيت —
; المُثبّت يعمل بصلاحية المسؤول أصلاً فلا تظهر أي نافذة UAC إضافية.
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Nexora Enterprise"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Nexora Enterprise"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes"; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Nexora Enterprise"" dir=out action=allow program=""{app}\{#MyAppExeName}"" enable=yes"; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; إزالة قاعدة جدار الحماية عند إلغاء التثبيت (نظافة).
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Nexora Enterprise"""; Flags: runhidden; RunOnceId: "DelFirewallRule"
