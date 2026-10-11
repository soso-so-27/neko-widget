[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigFile,[Parameter(Mandatory=$true)][string]$ConfigSHA256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$phase='configuration'
# This elevated process has NO HTTP listener, SQL, object access, decryptor or
# private-key reader. Only the fixed read-only key-directory validator runs.
try {
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $principal=New-Object Security.Principal.WindowsPrincipal($identity)
 if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'refused'}
 if((Get-FileHash -LiteralPath $ConfigFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ConfigSHA256){throw 'refused'}
 $config=Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
 if($config.schemaVersion -ne 1 -or $config.ownerSID -ne $identity.User.Value -or $config.pipeName -notmatch '^neko-owner-key-check-[0-9a-f-]{36}$' -or $config.keyId -ne 'moderation-v2' -or $config.publicKeySHA256 -notmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $config.securityScript -Algorithm SHA256).Hash.ToLowerInvariant() -ne $config.securityScriptSHA256){throw 'refused'}
 $until=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$config.expiresAtMs)
 if($until -le [DateTimeOffset]::UtcNow -or $until -gt [DateTimeOffset]::UtcNow.AddHours(24)){throw 'refused'}
 $pipeSecurity=New-Object IO.Pipes.PipeSecurity
 $pipeSecurity.SetAccessRuleProtection($true,$false)
 $pipeSecurity.SetOwner($identity.User)
 $rule=New-Object IO.Pipes.PipeAccessRule($identity.User,[IO.Pipes.PipeAccessRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
 $pipeSecurity.AddAccessRule($rule)
 $seen=New-Object 'System.Collections.Generic.HashSet[string]'
 $phase='native-metadata-helper'
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class NekoOwnerKeyFileIdentity {
 [StructLayout(LayoutKind.Sequential)] private struct Info {
  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
  public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
 public static string Inspect(string path) {
  using(var file=CreateFile(path,0,7,IntPtr.Zero,3,0,IntPtr.Zero)) {
   Info info;if(file.IsInvalid||!GetFileInformationByHandle(file,out info)||info.Links!=1)throw new Exception("refused");
   return info.Volume.ToString()+":"+(((ulong)info.IndexHigh<<32)|info.IndexLow).ToString()+":"+(((ulong)info.SizeHigh<<32)|info.SizeLow).ToString();
  }
 }
}
'@
 while([DateTimeOffset]::UtcNow -lt $until){
  $phase='pipe-listener'
  $pipe=New-Object IO.Pipes.NamedPipeServerStream($config.pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,$pipeSecurity)
  try {
   $connection=$pipe.BeginWaitForConnection($null,$null)
   if(-not $connection.AsyncWaitHandle.WaitOne([Math]::Min(30000,($until-[DateTimeOffset]::UtcNow).TotalMilliseconds))){continue}
   $pipe.EndWaitForConnection($connection)
   # Reject non-owner clients, including other logged-in desktop users.
   $reader=New-Object IO.StreamReader($pipe,[Text.Encoding]::UTF8,$false,1024,$true)
   $line=$reader.ReadLineAsync()
   if(-not $line.Wait(3000) -or $line.Result.Length -gt 256){throw 'refused'}
   $request=$line.Result | ConvertFrom-Json
   if(@($request.PSObject.Properties).Count -ne 2 -or $request.nonce -notmatch '^[0-9a-f]{64}$' -or -not $seen.Add($request.nonce) -or $seen.Count -gt 4096){throw 'refused'}
   $deadline=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$request.expiresAtMs)
   if($deadline -le [DateTimeOffset]::UtcNow -or $deadline -gt [DateTimeOffset]::UtcNow.AddSeconds(20)){throw 'refused'}
   if((Get-FileHash -LiteralPath $config.securityScript -Algorithm SHA256).Hash.ToLowerInvariant() -ne $config.securityScriptSHA256){throw 'refused'}
   $before=@('.private.raw','.public.base64url','.public.sha256') | ForEach-Object {[NekoOwnerKeyFileIdentity]::Inspect((Join-Path $config.keyDirectory ($config.keyId+$_)))}
   $sentinel=@(& $config.securityScript -Mode ValidateKeyDirectory -OutputDirectory $config.keyDirectory -ModerationKeyId $config.keyId -ConfirmLocalEncryptedNoSync)
   if($sentinel.Count -ne 1 -or $sentinel[0] -ne 'NEKO_MODERATION_KEYGEN_WINDOWS_VALIDATEKEYDIRECTORY_V1'){throw 'refused'}
   $publicText=[IO.File]::ReadAllText((Join-Path $config.keyDirectory ($config.keyId+'.public.base64url')))
   $publicBytes=[Convert]::FromBase64String($publicText.Replace('-','+').Replace('_','/')+'=')
   $hasher=[Security.Cryptography.SHA256]::Create()
   try{$fingerprint=([BitConverter]::ToString($hasher.ComputeHash($publicBytes))).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
   if($fingerprint -ne $config.publicKeySHA256 -or [DateTimeOffset]::UtcNow -ge $deadline){throw 'refused'}
   $files=@('.private.raw','.public.base64url','.public.sha256') | ForEach-Object {
    $name=$config.keyId+$_;$parts=[NekoOwnerKeyFileIdentity]::Inspect((Join-Path $config.keyDirectory $name)).Split(':')
    @{name=$name;volume=$parts[0];inode=$parts[1];size=[long]$parts[2]}
   }
   $after=@('.private.raw','.public.base64url','.public.sha256') | ForEach-Object {[NekoOwnerKeyFileIdentity]::Inspect((Join-Path $config.keyDirectory ($config.keyId+$_)))}
   if(($before -join '|') -ne ($after -join '|')){throw 'refused'}
   $result=@{nonce=$request.nonce;verifiedAtMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();publicKeySHA256=$fingerprint;custodyVerified=$true;keyDirectory=[IO.Path]::GetFullPath($config.keyDirectory);files=@($files)}
   $writer=New-Object IO.StreamWriter($pipe,(New-Object Text.UTF8Encoding($false)),1024,$true)
   $writer.WriteLine(($result | ConvertTo-Json -Depth 5 -Compress));$writer.Flush();$writer.Dispose();$reader.Dispose()
  } catch {
   # No errors, paths or credential material are sent through IPC. A missing
   # proof is a failure, and callers never cache or automatically retry it.
  } finally {$pipe.Dispose()}
 }
} catch {Write-Error ('Owner key validation broker unavailable: '+$phase+' ('+$_.Exception.GetType().Name+').');exit 1}
