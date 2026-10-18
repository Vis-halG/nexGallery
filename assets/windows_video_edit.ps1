param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][long]$StartMs,
    [Parameter(Mandatory=$true)][long]$EndMs,
    [ValidateSet(0,90,180,270)][int]$Rotation = 0,
    [int]$Mute = 0,
    [int]$Compress = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFolder,Windows.Storage,ContentType=WindowsRuntime]
$null = [Windows.Media.Editing.MediaClip,Windows.Media.Editing,ContentType=WindowsRuntime]
$null = [Windows.Media.Editing.MediaComposition,Windows.Media.Editing,ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.MediaEncodingProfile,Windows.Media.MediaProperties,ContentType=WindowsRuntime]
$taskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
$progressMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 2 -and $_.GetParameters().Count -eq 1
} | Select-Object -First 1
function Await($Operation, [Type]$ResultType) {
    $task = $taskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.GetAwaiter().GetResult()
}
if ($StartMs -lt 0 -or $EndMs -le $StartMs -or [IO.File]::Exists($OutputPath)) { throw 'Invalid export range or destination.' }
$source = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync([IO.Path]::GetFullPath($InputPath))) ([Windows.Storage.StorageFile])
$clip = Await ([Windows.Media.Editing.MediaClip]::CreateFromFileAsync($source)) ([Windows.Media.Editing.MediaClip])
if ($EndMs -gt $clip.OriginalDuration.TotalMilliseconds + 100) { throw 'Trim range exceeds the video duration.' }
$clip.TrimTimeFromStart = [TimeSpan]::FromMilliseconds($StartMs)
$clip.TrimTimeFromEnd = [TimeSpan]::FromMilliseconds([Math]::Max(0, $clip.OriginalDuration.TotalMilliseconds - $EndMs))
if ($Mute -eq 1) { $clip.Volume = 0.0 }
$inputVideo = $clip.GetVideoEncodingProperties()
$rotatedWidth = $inputVideo.Width
$rotatedHeight = $inputVideo.Height

$composition = New-Object Windows.Media.Editing.MediaComposition
$clipArguments = [Windows.Media.Editing.MediaClip[]]@($clip)
[System.Collections.Generic.ICollection[Windows.Media.Editing.MediaClip]].GetMethod('Add').Invoke($composition.Clips, $clipArguments)
$folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)))) ([Windows.Storage.StorageFolder])
$target = Await ($folder.CreateFileAsync([IO.Path]::GetFileName($OutputPath), [Windows.Storage.CreationCollisionOption]::FailIfExists)) ([Windows.Storage.StorageFile])
try {
    $profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::HD720p)
    $renderHeight = $rotatedHeight
    if ($Compress -eq 1) { $renderHeight = [Math]::Min(720, $rotatedHeight) }
    $profile.Video.Height = [uint32]([Math]::Max(2, [Math]::Floor($renderHeight / 2) * 2))
    $profile.Video.Width = [uint32]([Math]::Max(2, [Math]::Floor(($rotatedWidth * $renderHeight / $rotatedHeight) / 2) * 2))
    $profile.Video.FrameRate.Numerator = $inputVideo.FrameRate.Numerator
    $profile.Video.FrameRate.Denominator = $inputVideo.FrameRate.Denominator
    if ($Mute -eq 1) { $profile.Audio = $null }
    $operation = $composition.RenderToFileAsync($target, [Windows.Media.Editing.MediaTrimmingPreference]::Precise, $profile)
    $task = $progressMethod.MakeGenericMethod([Windows.Media.Transcoding.TranscodeFailureReason], [double]).Invoke($null, @($operation))
    $failure = $task.GetAwaiter().GetResult()
    if ($failure -ne [Windows.Media.Transcoding.TranscodeFailureReason]::None) { throw "Windows video export failed: $failure" }
} catch {
    if ([IO.File]::Exists($OutputPath)) { [IO.File]::Delete($OutputPath) }
    throw
}
