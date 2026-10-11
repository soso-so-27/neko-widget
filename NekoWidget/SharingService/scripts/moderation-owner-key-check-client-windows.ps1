[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BrokerRecord,[Parameter(Mandatory=$true)][string]$Nonce,[Parameter(Mandatory=$true)][long]$ExpiresAtMs)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
try {
 if($Nonce -notmatch '^[0-9a-f]{64}$'){throw 'refused'}
 $record=Get-Content -LiteralPath $BrokerRecord -Raw | ConvertFrom-Json
 if($record.schemaVersion -ne 1 -or $record.pipeName -notmatch '^neko-owner-key-check-[0-9a-f-]{36}$' -or $record.ownerSID -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'refused'}
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class NekoOwnerPipePeer {
 [StructLayout(LayoutKind.Sequential)] private struct Info {
  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
  public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] private static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref uint length);
 [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
 public static string ProcessPath(uint pid) {
  var handle=OpenProcess(0x1000,false,pid);if(handle==IntPtr.Zero)throw new Exception("refused");
  try{var path=new StringBuilder(32768);uint length=32768;if(!QueryFullProcessImageName(handle,0,path,ref length))throw new Exception("refused");return path.ToString();}
  finally{CloseHandle(handle);}
 }
 public static string FileIdentity(string path) {
  using(var file=CreateFile(path,0,7,IntPtr.Zero,3,0,IntPtr.Zero)) {
   Info info;if(file.IsInvalid||!GetFileInformationByHandle(file,out info)||info.Links!=1||(info.Attributes&0x400)!=0)throw new Exception("refused");
   return info.Volume.ToString()+":"+(((ulong)info.IndexHigh<<32)|info.IndexLow).ToString()+":"+(((ulong)info.SizeHigh<<32)|info.SizeLow).ToString();
  }
 }
}
'@
 $pipe=New-Object IO.Pipes.NamedPipeClientStream('.', $record.pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 try {
  $pipe.Connect(3000);[uint32]$peerID=0
  if(-not [NekoOwnerPipePeer]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$peerID) -or $peerID -ne $record.brokerPID){throw 'refused'}
  $peer=Get-Process -Id $peerID
  if($peer.StartTime.ToUniversalTime().Ticks.ToString() -ne $record.brokerStartTicks -or [NekoOwnerPipePeer]::ProcessPath($peerID) -ne (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')){throw 'refused'}
  $writer=New-Object IO.StreamWriter($pipe,(New-Object Text.UTF8Encoding($false)),1024,$true)
  $writer.WriteLine((@{nonce=$Nonce;expiresAtMs=$ExpiresAtMs} | ConvertTo-Json -Compress));$writer.Flush()
  $reader=New-Object IO.StreamReader($pipe,[Text.Encoding]::UTF8,$false,1024,$true)
  $task=$reader.ReadLineAsync();if(-not $task.Wait(15000) -or $task.Result.Length -gt 2048){throw 'refused'}
  $proof=$task.Result | ConvertFrom-Json
  if($proof.nonce -ne $Nonce -or -not $proof.custodyVerified -or $proof.publicKeySHA256 -ne $record.publicKeySHA256 -or $proof.keyDirectory -ne [IO.Path]::GetFullPath($record.keyDirectory) -or @($proof.files).Count -ne 3 -or $proof.verifiedAtMs -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -or [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$proof.verifiedAtMs -gt 3000 -or [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge $ExpiresAtMs){throw 'refused'}
  foreach($file in $proof.files){
   if($file.name -notmatch '^moderation-v2\.(private\.raw|public\.base64url|public\.sha256)$'){throw 'refused'}
   $actual=[NekoOwnerPipePeer]::FileIdentity((Join-Path $record.keyDirectory $file.name))
   if($actual -ne ($file.volume+':'+$file.inode+':'+$file.size)){throw 'refused'}
  }
  Write-Output ($proof | ConvertTo-Json -Depth 5 -Compress)
 } finally {$pipe.Dispose()}
}catch{Write-Error 'Owner key custody proof unavailable.';exit 1}
