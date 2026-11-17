@echo off
rem Build APK va dua len trang tai (download_site). Xem download_site\README.md.
rem Vi du:  tool\publish_release.cmd --notes "Sua loi dong bo"
setlocal
set "SITE=%~dp0..\download_site"
if not exist "%SITE%\node_modules" (
  echo [publish_release] Cai thu vien cho download_site...
  pushd "%SITE%"
  call npm install --no-audit --no-fund
  if errorlevel 1 (
    popd
    exit /b 1
  )
  popd
)
node "%SITE%\scripts\release.mjs" %*
exit /b %ERRORLEVEL%
