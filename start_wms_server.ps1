$ErrorActionPreference = 'SilentlyContinue'
$port = 8080
$already = Get-NetTCPConnection -State Listen -LocalPort $port
if ($already) { exit 0 }
Set-Location 'C:\Users\Farxod3376\Documents\Default Project\warehouse'
$log = 'C:\Users\Farxod3376\Documents\Default Project\warehouse\server_run.log'
& 'C:\tools\flutter-sdk\flutter\bin\cache\dart-sdk\bin\dart.exe' 'run' 'bin\server.dart' *>> $log
exit $LASTEXITCODE