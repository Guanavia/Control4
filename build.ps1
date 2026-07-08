Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$srcDir = Join-Path $PSScriptRoot "nv_shield_tv"
$outFile = Join-Path $PSScriptRoot "nv_shield_tv-dmw.c4z"

if (Test-Path $outFile) { Remove-Item $outFile }

$stream = [System.IO.File]::Open($outFile, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)

Get-ChildItem -Path $srcDir -Recurse -File | ForEach-Object {
    $entryName = $_.FullName.Substring($srcDir.Length + 1).Replace('\', '/')
    $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    $fileStream = [System.IO.File]::OpenRead($_.FullName)
    $fileStream.CopyTo($entryStream)
    $fileStream.Close()
    $entryStream.Close()
}

$zip.Dispose()
$stream.Dispose()

Write-Host "Done: nv_shield_tv-dmw.c4z"
