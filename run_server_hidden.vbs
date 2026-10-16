Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c cd /d C:\Users\Farxod3376\Documents\Default Project\warehouse && C:\tools\flutter-sdk\flutter\bin\cache\dart-sdk\bin\dart.exe run bin\server.dart >> server_run.log 2>&1", 0, False
Set WshShell = Nothing
