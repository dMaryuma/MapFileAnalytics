# Script powershell for mapping all files inside File Analytics Volume into csv file per Volume

# skip certificate
[Net.ServicePointManager]::SecurityProtocol = [Net.securityProtocolType]::Tls12
    Add-Type -TypeDefinition @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
$uri = "https://your_cluster_ip/api"
$cred = Get-Credential -Message "Enter credentials of NetApp system: $($netapp_systems)"
$svm = "svm1"
$csvPath = "C:\Users\Administrator.DEMO\Downloads\"

function Get-VolumeFilesRecursive {
    param (
        [string]$BaseUri,
        [PSCredential]$Cred,
        [string]$RelativePath = "",
        [string]$VolName,
        [string]$SVM
    )

    $results = @()

    # Encode path for URL if not empty
    $encodedPath = if ($RelativePath -eq "") { "" } else { [uri]::EscapeDataString($RelativePath) }

    # Build the request URI with fields=*
    $uri = if ($encodedPath -eq "") {
        "$BaseUri`?fields=*"
    }
    else {
        "$BaseUri/$encodedPath`?fields=*"
    }

    # Query current folder
    $response = Invoke-RestMethod -Method 'Get' -Uri $uri -Credential $Cred

    foreach ($item in $response.records) {
        # Skip system folders
        if ($item.name -in @(".", "..", ".snapshot")) { continue }

        # Full logical path
        $fullPath = if ($RelativePath -eq "") { $item.name } else { "$RelativePath/$($item.name)" }

        if ($item.type -eq "file") {
            # Build PSCustomObject with all fields
            $results += [PSCustomObject]@{
                Volume         = $VolName
                SVM            = $SVM
                FullPath       = $fullPath
                Name           = $item.name
                Type           = $item.type
                Size           = $item.size
                Owner          = $item.owner_id
                Group          = $item.group_id
                UnixPerms      = $item.unix_permissions
                Created        = [datetime]$item.creation_time
                Modified       = [datetime]$item.modified_time
                Accessed       = [datetime]$item.accessed_time
                Changed        = [datetime]$item.changed_time
                Inode          = $item.inode_number
                HardLinks      = $item.hard_links_count
                BytesUsed      = $item.bytes_used
                IsSnapshot     = $item.is_snapshot
                IsJunction     = $item.is_junction
                IsVmAligned    = $item.is_vm_aligned
            }
        }

        # If directory → recurse
        if ($item.type -eq "directory") {
            Write-Host "Working on folder: $fullPath"
            $results += Get-VolumeFilesRecursive -BaseUri $BaseUri -Cred $Cred -RelativePath $fullPath -VolName $VolName -SVM $SVM
        }
    }

    return $results
}
################
##### Main #####
################
try{
    # get volumes with FSA on
    $volumes_response = Invoke-RestMethod -Method 'Get' -Uri "$($uri)/storage/volumes?analytics.state=on&fields=svm.name" -Credential $cred
    $counter = 1
    foreach ($vol in $volumes_response.records){
        Write-Host "Working on volume: $($vol.svm.name):$($vol.name), num $counter/$($volumes_response.count)"
        $base_uri_volume_explor = "$uri/storage/volumes/$($vol.uuid)/files"
        #$response_volume_folders = Invoke-RestMethod -Method 'Get' -Uri "$base_uri_volume_explor" -Credential $cred
        $fileList = Get-VolumeFilesRecursive -BaseUri $base_uri_volume_explor -Cred $cred -VolName $vol.name -SVM $vol.svm.name
        # Export per volume
        $csvSuffix = "$($vol.svm.name)_$($vol.name).csv"
        $fileList | Export-Csv -Path "$csvPath\$csvSuffix" -NoTypeInformation -Encoding UTF8

        Write-Host "Exported $($fileList.Count) files to $csvPath"
        $counter++
    }
}catch{Write-Host $_}
