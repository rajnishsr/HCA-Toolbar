@ echo OFF
@ Taskkill /F /IM Toolbar.exe
@ Taskkill /F /M Reserve-Top.exe
@ ECHO Restarting Toolbar
@ Start "Toolbar Refresh" "C:\ProgramData\ToolbarApp\Toolbar.exe"
@ Start "Toolbar Refresh" "C:\ProgramData\ToolbarApp\Reserve-Top.exe"
