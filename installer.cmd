@echo off

REM Run the bash script using BusyBox
"c:\Program Files\Git\bin\bash.exe" installer.sh

REM Wait for any key
echo "==================================================="
echo "Нажмите любую клавишу для выхода..."
echo "==================================================="
pause
