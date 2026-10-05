#requires -Version 5.1
<#
  يطبّق هوية نيكسورا البصرية على منصة ويندوز (حتى بعد إعادة توليدها بـ flutter create):
    1) يستبدل أيقونة التطبيق resources\app_icon.ico (يحتوي كل المقاسات 16..256).
    2) يحدّث عنوان النافذة إلى «نيكسورا» (بترميز \u آمن لا يعتمد على ترميز الملف).
    3) يثبّت أيقونة شريط المهام وترويسة النافذة صراحةً عبر WM_SETICON.
  الاستخدام: pwsh -File scripts\apply_windows_branding.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$icon = Join-Path $root 'assets\icons\app_icon.ico'
$resDir = Join-Path $root 'windows\runner\resources'
$res = Join-Path $resDir 'app_icon.ico'
$main = Join-Path $root 'windows\runner\main.cpp'

if (-not (Test-Path $icon)) { throw "ملف الأيقونة غير موجود: $icon" }
if (-not (Test-Path $main)) { throw "ملف main.cpp غير موجود: $main" }

# 1) الأيقونة
New-Item -ItemType Directory -Force -Path $resDir | Out-Null
Copy-Item -Path $icon -Destination $res -Force
Write-Host "✔ تم تحديث أيقونة ويندوز: $res"

$src = Get-Content -Path $main -Raw -Encoding UTF8
$changed = $false

# 2) تضمين resource.h
if ($src -notmatch '#include\s+"resource\.h"') {
  $src = $src -replace '(#include\s+"utils\.h")', "`$1`r`n#include `"resource.h`""
  $changed = $true
  Write-Host '✔ أُضيف #include "resource.h"'
}

# 3) عنوان النافذة — نيكسورا (ترميز \u مستقل عن ترميز الملف)
if ($src -match 'window\.Create\(L"[^"]*"') {
  $src = $src -replace 'window\.Create\(L"[^"]*"', 'window.Create(L"\u0646\u064A\u0643\u0633\u0648\u0631\u0627"'
  $changed = $true
  Write-Host '✔ عُدّل عنوان النافذة إلى «نيكسورا»'
}

# 4) أيقونة شريط المهام وترويسة النافذة
if ($src -notmatch 'WM_SETICON') {
  $block = @'

  // أيقونة التطبيق: تُثبَّت صراحةً على النافذة (الترويسة) وشريط المهام.
  HICON app_icon = ::LoadIcon(instance, MAKEINTRESOURCE(IDI_APP_ICON));
  if (app_icon != nullptr) {
    ::SendMessageW(window.GetHandle(), WM_SETICON, ICON_BIG,
                   reinterpret_cast<LPARAM>(app_icon));
    ::SendMessageW(window.GetHandle(), WM_SETICON, ICON_SMALL,
                   reinterpret_cast<LPARAM>(app_icon));
  }
'@
  $src = $src -replace '(  window\.SetQuitOnClose\(true\);)', "`$1`r`n$block"
  $changed = $true
  Write-Host '✔ أُضيف تثبيت أيقونة شريط المهام والترويسة'
}

if ($changed) {
  [System.IO.File]::WriteAllText($main, $src, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "✔ حُدِّث: $main"
}

# 5) بيانات المنتج في Runner.rc (ASCII لتفادي مشاكل ترميز مترجم الموارد).
$rcPath = Join-Path $root 'windows\runner\Runner.rc'
if (Test-Path $rcPath) {
  $rc = Get-Content -Path $rcPath -Raw -Encoding UTF8
  $rc = $rc -replace 'VALUE "CompanyName", "[^"]*"', 'VALUE "CompanyName", "Nexora"'
  $rc = $rc -replace 'VALUE "FileDescription", "[^"]*"', 'VALUE "FileDescription", "Nexora - Sales & Debts Manager"'
  $rc = $rc -replace 'VALUE "ProductName", "[^"]*"', 'VALUE "ProductName", "Nexora"'
  [System.IO.File]::WriteAllText($rcPath, $rc, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "✔ حُدِّث بيانات المنتج: $rcPath"
}
else {
  Write-Host '· لا تغيير — الهوية مطبّقة سلفاً.'
}
