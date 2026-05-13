@echo off
setlocal

set "ROOT=C:\winforge"
mkdir "%ROOT%" 2>nul
echo %DATE% %TIME% SetupComplete starting>>"%ROOT%\setupcomplete.log"

for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist %%D:\install-winforge-bootstrap.ps1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File %%D:\install-winforge-bootstrap.ps1 >>"%ROOT%\setupcomplete.log" 2>&1
    exit /b %errorlevel%
  )
)

echo bootstrap media not found>>"%ROOT%\setupcomplete.log"
exit /b 1
