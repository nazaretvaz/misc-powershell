function Unzip-File {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$PathToZip,
        
        [Parameter(Mandatory=$true,Position=1)]
        [string]$TargetDir,

        [Parameter(Mandatory=$false,Position=2)]
        [string[]]$SpecificItem
    )

    if ($PSVersionTable.PSEdition -eq "Core") {
        [System.Collections.ArrayList]$AssembliesToCheckFor = @("System.Console","System","System.IO",
            "System.IO.Compression","System.IO.Compression.Filesystem","System.IO.Compression.ZipFile"
        )

        [System.Collections.ArrayList]$NeededAssemblies = @()

        foreach ($assembly in $AssembliesToCheckFor) {
            try {
                [System.Collections.ArrayList]$Failures = @()
                try {
                    $TestLoad = [System.Reflection.Assembly]::LoadWithPartialName($assembly)
                    if (!$TestLoad) {
                        throw
                    }
                }
                catch {
                    $null = $Failures.Add("Failed LoadWithPartialName")
                }

                try {
                    $null = Invoke-Expression "[$assembly]"
                }
                catch {
                    $null = $Failures.Add("Failed TabComplete Check")
                }

                if ($Failures.Count -gt 1) {
                    $Failures
                    throw
                }
            }
            catch {
                Write-Host "Downloading $assembly..."
                $NewAssemblyDir = "$HOME\Downloads\$assembly"
                $NewAssemblyDllPath = "$NewAssemblyDir\$assembly.dll"
                if (!$(Test-Path $NewAssemblyDir)) {
                    New-Item -ItemType Directory -Path $NewAssemblyDir
                }
                if (Test-Path "$NewAssemblyDir\$assembly*.zip") {
                    Remove-Item "$NewAssemblyDir\$assembly*.zip" -Force
                }
                $OutFileBaseNamePrep = Invoke-WebRequest "https://www.nuget.org/api/v2/package/$assembly" -DisableKeepAlive -UseBasicParsing
                $OutFileBaseName = $($OutFileBaseNamePrep.BaseResponse.ResponseUri.AbsoluteUri -split "/")[-1] -replace "nupkg","zip"
                Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/$assembly" -OutFile "$NewAssemblyDir\$OutFileBaseName"
                Expand-Archive -Path "$NewAssemblyDir\$OutFileBaseName" -DestinationPath $NewAssemblyDir

                $PossibleDLLs = Get-ChildItem -Recurse $NewAssemblyDir | Where-Object {$_.Name -eq "$assembly.dll" -and $_.Parent -notmatch "net[0-9]" -and $_.Parent -match "core|standard"}

                if ($PossibleDLLs.Count -gt 1) {
                    Write-Warning "More than one item within $NewAssemblyDir\$OutFileBaseName matches $assembly.dll"
                    Write-Host "Matches include the following:"
                    for ($i=0; $i -lt $PossibleDLLs.Count; $i++){
                        "$i) $($($PossibleDLLs[$i]).FullName)"
                    }
                    $Choice = Read-Host -Prompt "Please enter the number corresponding to the .dll you would like to load [0..$($($PossibleDLLs.Count)-1)]"
                    if ($(0..$($($PossibleDLLs.Count)-1)) -notcontains $Choice) {
                        Write-Error "The number indicated does is not a valid choice! Halting!"
                        $global:FunctionResult = "1"
                        return
                    }

                    if ($PSVersionTable.Platform -eq "Win32NT") {
                        # Install to GAC
                        [System.Reflection.Assembly]::LoadWithPartialName("System.EnterpriseServices")
                        $publish = New-Object System.EnterpriseServices.Internal.Publish
                        $publish.GacInstall($PossibleDLLs[$Choice].FullName)
                    }

                    # Copy it to the root of $NewAssemblyDir\$OutFileBaseName
                    Copy-Item -Path "$($PossibleDLLs[$Choice].FullName)" -Destination "$NewAssemblyDir\$assembly.dll"

                    # Remove everything else that was extracted with Expand-Archive
                    Get-ChildItem -Recurse $NewAssemblyDir | Where-Object {
                        $_.FullName -ne "$NewAssemblyDir\$assembly.dll" -and
                        $_.FullName -ne "$NewAssemblyDir\$OutFileBaseName"
                    } | Remove-Item -Recurse -Force
                    
                }
                if ($PossibleDLLs.Count -lt 1) {
                    Write-Error "No matching .dll files were found within $NewAssemblyDir\$OutFileBaseName ! Halting!"
                    continue
                }
                if ($PossibleDLLs.Count -eq 1) {
                    if ($PSVersionTable.Platform -eq "Win32NT") {
                        # Install to GAC
                        [System.Reflection.Assembly]::LoadWithPartialName("System.EnterpriseServices")
                        $publish = New-Object System.EnterpriseServices.Internal.Publish
                        $publish.GacInstall($PossibleDLLs.FullName)
                    }

                    # Copy it to the root of $NewAssemblyDir\$OutFileBaseName
                    Copy-Item -Path "$($PossibleDLLs[$Choice].FullName)" -Destination "$NewAssemblyDir\$assembly.dll"

                    # Remove everything else that was extracted with Expand-Archive
                    Get-ChildItem -Recurse $NewAssemblyDir | Where-Object {
                        $_.FullName -ne "$NewAssemblyDir\$assembly.dll" -and
                        $_.FullName -ne "$NewAssemblyDir\$OutFileBaseName"
                    } | Remove-Item -Recurse -Force
                }
            }
            $AssemblyFullInfo = [System.Reflection.Assembly]::LoadWithPartialName($assembly)
            if (!$AssemblyFullInfo) {
                $AssemblyFullInfo = [System.Reflection.Assembly]::LoadFile("$NewAssemblyDir\$assembly.dll")
            }
            if (!$AssemblyFullInfo) {
                Write-Error "The assembly $assembly could not be found or otherwise loaded! Halting!"
                $global:FunctionResult = "1"
                return
            }
            $null = $NeededAssemblies.Add([pscustomobject]@{
                AssemblyName = "$assembly"
                Available = if ($AssemblyFullInfo){$true} else {$false}
                AssemblyInfo = $AssemblyFullInfo
                AssemblyLocation = $AssemblyFullInfo.Location
            })
        }

        if ($NeededAssemblies.Available -contains $false) {
            $AssembliesNotFound = $($NeededAssemblies | Where-Object {$_.Available -eq $false}).AssemblyName
            Write-Error "The following assemblies cannot be found:`n$AssembliesNotFound`nHalting!"
            $global:FunctionResult = "1"
            return
        }

        $Assem = $NeededAssemblies.AssemblyInfo.FullName

        $Source = @"
        using System;
        using System.IO;
        using System.IO.Compression;

        namespace MyCore.Utils
        {
            public static class Zip
            {
                public static void ExtractAll(string sourcepath, string destpath)
                {
                    string zipPath = @sourcepath;
                    string extractPath = @destpath;

                    using (ZipArchive archive = ZipFile.Open(zipPath, ZipArchiveMode.Update))
                    {
                        archive.ExtractToDirectory(extractPath);
                    }
                }

                public static void ExtractSpecific(string sourcepath, string destpath, string specificitem)
                {
                    string zipPath = @sourcepath;
                    string extractPath = @destpath;
                    string itemout = @specificitem.Replace(@"\","/");

                    //Console.WriteLine(itemout);

                    using (ZipArchive archive = ZipFile.OpenRead(zipPath))
                    {
                        foreach (ZipArchiveEntry entry in archive.Entries)
                        {
                            //Console.WriteLine(entry.FullName);
                            //bool satisfied = new bool();
                            //satisfied = entry.FullName.IndexOf(@itemout, 0, StringComparison.CurrentCultureIgnoreCase) != -1;
                            //Console.WriteLine(satisfied);

                            if (entry.FullName.IndexOf(@itemout, 0, StringComparison.CurrentCultureIgnoreCase) != -1)
                            {
                                string finaloutputpath = extractPath + "\\" + entry.Name;
                                entry.ExtractToFile(finaloutputpath, true);
                            }
                        }
                    } 
                }
            }
        }
"@

        Add-Type -ReferencedAssemblies $Assem -TypeDefinition $Source

        if (!$SpecificItem) {
            [MyCore.Utils.Zip]::ExtractAll($PathToZip, $TargetDir)
        }
        else {
            [MyCore.Utils.Zip]::ExtractSpecific($PathToZip, $TargetDir, $SpecificItem)
        }
    }

    if ($PSVersionTable.PSEdition -eq "Desktop" -and $($($PSVersionTable.Platform -and $PSVersionTable.Platform -eq "Win32NT") -or !$PSVersionTable.Platform)) {
        if ($SpecificItem) {
            foreach ($item in $SpecificItem) {
                if ($SpecificItem -match "\\") {
                    $SpecificItem = $SpecificItem -replace "\\","\\"
                }
            }
        }

        ##### BEGIN Native Helper Functions #####
        function Get-ZipChildItems {
            [CmdletBinding()]
            Param(
                [Parameter(Mandatory=$false,Position=0)]
                [string]$ZipFile = $(Read-Host -Prompt "Please enter the full path to the zip file")
            )

            $shellapp = new-object -com shell.application
            $zipFileComObj = $shellapp.Namespace($ZipFile)
            $i = $zipFileComObj.Items()
            Get-ZipChildItems_Recurse $i
        }

        function Get-ZipChildItems_Recurse {
            [CmdletBinding()]
            Param(
                [Parameter(Mandatory=$true,Position=0)]
                $items
            )

            foreach($si in $items) {
                if($si.getfolder -ne $null) {
                    # Loop through subfolders 
                    Get-ZipChildItems_Recurse $si.getfolder.items()
                }
                # Spit out the object
                $si
            }
        }

        ##### END Native Helper Functions #####

        ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####
        if (!$(Test-Path $PathToZip)) {
            Write-Verbose "The path $PathToZip was not found! Halting!"
            Write-Error "The path $PathToZip was not found! Halting!"
            $global:FunctionResult = "1"
            return
        }
        if ($(Get-ChildItem $PathToZip).Extension -ne ".zip") {
            Write-Verbose "The file specified by the -PathToZip parameter does not have a .zip file extension! Halting!"
            Write-Error "The file specified by the -PathToZip parameter does not have a .zip file extension! Halting!"
            $global:FunctionResult = "1"
            return
        }

        $ZipFileNameWExt = $(Get-ChildItem $PathToZip).Name

        ##### END Variable/Parameter Transforms and PreRun Prep #####

        ##### BEGIN Main Body #####

        Write-Verbose "NOTE: PowerShell 5.0 uses Expand-Archive cmdlet to unzip files"

        if (!$SpecificItem) {
            if ($PSVersionTable.PSVersion.Major -ge 5) {
                Expand-Archive -Path $PathToZip -DestinationPath $TargetDir
            }
            if ($PSVersionTable.PSVersion.Major -lt 5) {
                # Load System.IO.Compression.Filesystem 
                [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null

                # Unzip file
                [System.IO.Compression.ZipFile]::ExtractToDirectory($PathToZip, $TargetDir)
            }
        }
        if ($SpecificItem) {
            $ZipSubItems = Get-ZipChildItems -ZipFile $PathToZip

            foreach ($searchitem in $SpecificItem) {
                [array]$potentialItems = foreach ($item in $ZipSubItems) {
                    if ($item.Path -match $searchitem) {
                        $item
                    }
                }

                $shell = new-object -com shell.application

                if ($potentialItems.Count -eq 1) {
                    $shell.Namespace($TargetDir).CopyHere($potentialItems[0], 0x14)
                }
                if ($potentialItems.Count -gt 1) {
                    Write-Warning "More than one item within $ZipFileNameWExt matches $searchitem."
                    Write-Host "Matches include the following:"
                    for ($i=0; $i -lt $potentialItems.Count; $i++){
                        "$i) $($($potentialItems[$i]).Path)"
                    }
                    $Choice = Read-Host -Prompt "Please enter the number corresponding to the item you would like to extract [0..$($($potentialItems.Count)-1)]"
                    if ($(0..$($($potentialItems.Count)-1)) -notcontains $Choice) {
                        Write-Warning "The number indicated does is not a valid choice! Skipping $searchitem..."
                        continue
                    }
                    for ($i=0; $i -lt $potentialItems.Count; $i++){
                        $shell.Namespace($TargetDir).CopyHere($potentialItems[$Choice], 0x14)
                    }
                }
                if ($potentialItems.Count -lt 1) {
                    Write-Warning "No items within $ZipFileNameWExt match $searchitem! Skipping..."
                    continue
                }
            }
        }
        ##### END Main Body #####
    }
}

function Get-AssemblyAvailability {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string]$AssemblyName
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    $AssemblyBaseClassCount = $($AssemblyName -split "\.").Count

    [System.Collections.ArrayList]$AttemptedAssemblyPermutations = @()

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    try {
        [System.Collections.ArrayList]$Failures = @()
        try {
            $AssemPartName = [System.Reflection.Assembly]::LoadWithPartialName($AssemblyName)
            if (!$AssemPartName) {
                throw
            }
            $WorkingAssemblyReference = $AssemPartName
        }
        catch {
            $null = $Failures.Add("Failed LoadWithPartialName")
        }

        try {
            $AssemTab = $(Invoke-Expression "[$AssemblyName]").Assembly
            $WorkingAssemblyReference = $AssemTab
        }
        catch {
            $null = $Failures.Add("Failed TabComplete Check")
        }

        try {
            $GACDir = [System.AppDomain]::CurrentDomain.GetAssemblies()[0].Location | Split-Path -Parent
            $GACChildItems = Get-ChildItem -Recurse $GACDir
            Filter FindAssemFilter {
                if ($_.Location -like "*$AssemblyName.dll") {
                    $_.Location
                    break
                }
            }
            $AssemblyFileLocation = $GACChildItems.FullName | FindAssemFilter
            if ($AssemblyFileLocation) {
                $AssemLoadFile = [System.Reflection.Assembly]::LoadFile($AssemblyFileLocation)
                if ($AssemLoadFile) {
                    $WorkingAssemblyReference = $AssemLoadFile
                }
                else {
                    throw
                }
            }
            else {
                throw
            }
        }
        catch {
            $null = $Failures.Add("Failed LoadFile Check")
        }

        if ($Failures.Count -gt 2) {
            throw
        }
    }
    catch {
        $null = $AttemptedAssemblyPermutations.Add($AssemblyName)

        if ($AssemblyBaseClassCount -ge 3) {
            for ($i=0; $i -lt $($AssemblyBaseClassCount-2); $i++) {
                $AssemblyName = $AssemblyName.Substring(0, $AssemblyName.LastIndexOf("."))

                [System.Collections.ArrayList]$Failures = @()
                try {
                    $Assem = [System.Reflection.Assembly]::LoadWithPartialName($AssemblyName)
                    if (!$Assem) {
                        throw
                    }
                    $WorkingAssemblyReference = $Assem
                    break
                }
                catch {
                    $null = $Failures.Add("Failed LoadWithPartialName")
                }

                try {
                    $Assem = $(Invoke-Expression "[$AssemblyName]").Assembly
                    $WorkingAssemblyReference = $Assem
                    break
                }
                catch {
                    $null = $Failures.Add("Failed TabComplete Check")
                }

                try {
                    $GACDir = [System.AppDomain]::CurrentDomain.GetAssemblies()[0].Location | Split-Path -Parent
                    $GACChildItems = Get-ChildItem -Recurse $GACDir
                    Filter FindAssemFilter {
                        if ($_.Location -like "*$AssemblyName.dll") {
                            $_.Location
                            break
                        }
                    }
                    $AssemblyFileLocation = $GACChildItems.FullName | FindAssemFilter
                    if ($AssemblyFileLocation) {
                        $AssemLoadFile = [System.Reflection.Assembly]::LoadFile($AssemblyFileLocation)
                        if ($AssemLoadFile) {
                            $WorkingAssemblyReference = $AssemLoadFile
                        }
                        else {
                            throw
                        }
                    }
                    else {
                        throw
                    }
                }
                catch {
                    $null = $Failures.Add("Failed LoadFile Check")
                }

                if ($Failures.Count -gt 2) {
                    $null = $AttemptedAssemblyPermutations.Add($AssemblyName)
                }
            }
        }
    }

    if (!$WorkingAssemblyReference) {
        Write-Error "The following attempts at loading the assembly $AssemblyName were made and ALL failed:`n$AttemptedAssemblyPermutations`nHalting!"
        $global:FunctionResult = "1"
        return
    }
    else {
        $WorkingAssemblyReference
    }

    ##### END Main Body #####
}

function Get-AssemblyUsingStatement {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string]$AssemblyName,

        [Parameter(Mandatory=$True)]
        $AssemblyFullInfo,

        [Parameter(Mandatory=$False)]
        [switch]$Silent
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    # Make sure the $AssemblyName matches the $AssemblyFullInfo
    
    if ($AssemblyName -notlike "*$($($AssemblyFullInfo.FullName -split ",")[0])*") {
        Write-Error "The Assembly Reference '$($AssemblyFullInfo.FullName)' does not contain the Assembly Name $AssemblyName! Halting!"
        $global:FunctionResult = "1"
        return
    }

    $UsingStatement = "using $AssemblyName;"

    $AssemblyBaseClassCount = $($AssemblyName -split "\.").Count

    [System.Collections.ArrayList]$AttemptedUsingStatements = @()

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    try {
        $WarningPreference = "SilentlyContinue"
        Add-Type -ReferencedAssemblies $AssemblyFullInfo -TypeDefinition $UsingStatement -IgnoreWarnings -ErrorAction SilentlyContinue
        $WarningPreference = "Continue"
        $UsingStatementWorks = $true
        $FinalUsingStatement = $UsingStatement
    }
    catch {
        $null = $AttemptedUsingStatements.Add($UsingStatement)
        if (!$Silent) {
            Write-Error "$($Error[1])"
        }
        if ($AssemblyBaseClassCount -ge 3) {
            for ($i=0; $i -lt $($AssemblyBaseClassCount-2); $i++) {
                $AssemblyName = $AssemblyName.Substring(0, $AssemblyName.LastIndexOf("."))
                $UsingStatement = "using $AssemblyName;"

                try {
                    Add-Type -ReferencedAssemblies $AssemblyFullInfo -TypeDefinition $UsingStatement -ErrorAction SilentlyContinue
                    $FinalUsingStatement = "using $AssemblyName;"
                    break
                }
                catch {
                    $null = $AttemptedUsingStatements.Add($UsingStatement)
                    if (!$Silent) {
                        Write-Error "$($Error[1])"
                    }
                    if ($i -eq ($AssemblyBaseClassCount-1)) {
                        $FinalUsingStatement = $null
                    }
                }
            }
        }
        else {
            $FinalUsingStatement = $null
        }
    }

    if ($FinalUsingStatement -eq $null) {
        Write-Error "The following `"using`" statements were attempted for $AssemblyName and ALL failed:`n$AttemptedUsingStatements`nHalting!"
        $global:FunctionResult = "1"
        return
    }

    $FinalUsingStatement

    ##### END Main Body #####
}

function Install-AssemblyViaNuGet {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string]$AssemblyName
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    [System.Collections.ArrayList]$PotentialZipSubDirs = @()
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        $null = $PotentialZipSubDirs.Add("lib\net$($PSVersionTable.CLRVersion.Major)" + "$($PSVersionTable.CLRVersion.Minor)")
    }

    if ($PSVersionTable.PSEdition -eq "Core") {
        $null = $PotentialZipSubDirs.Add("lib\netstandard1.0")
        $null = $PotentialZipSubDirs.Add("lib\netstandard1.3")
        $null = $PotentialZipSubDirs.Add("lib\netstandard1.6")
    }

    ##### END Variable/Parameter Transforms and PreRun Prep #####

    
    ##### BEGIN Main Body #####

    Write-Host "Downloading $AssemblyName..."

    $NewAssemblyDir = "$HOME\Downloads\$AssemblyName"
    $NewAssemblyDllPath = "$NewAssemblyDir\$AssemblyName.dll"

    if (!$(Test-Path $NewAssemblyDir)) {
        New-Item -ItemType Directory -Path $NewAssemblyDir
    }
    if (Test-Path "$NewAssemblyDir\$AssemblyName*.zip") {
        Remove-Item "$NewAssemblyDir\$AssemblyName*.zip" -Force
    }

    try {
        $OutFileBaseNamePrep = Invoke-WebRequest "https://www.nuget.org/api/v2/package/$AssemblyName" -DisableKeepAlive -UseBasicParsing -ErrorAction SilentlyContinue
        $OutFileBaseName = $($OutFileBaseNamePrep.BaseResponse.ResponseUri.AbsoluteUri -split "/")[-1] -replace "nupkg","zip"
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/$AssemblyName" -OutFile "$NewAssemblyDir\$OutFileBaseName" -ErrorAction SilentlyContinue
    }
    catch {
        Write-Error "Unable to download from https://www.nuget.org/api/v2/package/$AssemblyName! Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($PSVersionTable.PSEdition -eq "Core" -or $PSVersionTable.PSEdition -eq "Desktop") {
        [System.Collections.ArrayList]$NotFound = @()
        [System.Collections.ArrayList]$Found = @()

        foreach ($subdir in $PotentialZipSubDirs) {
            try {
                $global:FunctionResult = "0"
                Unzip-File -PathToZip "$NewAssemblyDir\$OutFileBaseName" -TargetDir $NewAssemblyDir -SpecificItem "$subdir\$AssemblyName.dll"
                if ($global:FunctionResult -eq "0") {
                    Write-Host "$subdir\$AssemblyName.dll"
                    $null = $Found.Add("$subdir\$AssemblyName.dll")
                }
                else {
                    throw
                }
            }
            catch {
                Write-Error "$subdir\$AssemblyName.dll not found within the zip file $NewAssemblyDir\$OutFileBaseName..."
                $null = $NotFound.Add("$subdir\$AssemblyName.dll not found")
            }

            if ($Found.Count -gt 0) {
                if (!$PSVersionTable.Platform -or $PSVersionTable.Platform -eq "Win32NT") {
                    # Install to GAC
                    [System.Reflection.Assembly]::LoadWithPartialName("System.EnterpriseServices")
                    $publish = New-Object System.EnterpriseServices.Internal.Publish
                    $publish.GacInstall("$NewAssemblyDir\$AssemblyName.dll")
                }
                if ($PSVersionTable.Platform -eq "Linux") {
                    $GACEquivalentPath = [System.AppDomain]::CurrentDomain.GetAssemblies()[0].Location | Split-Path -Parent
                    Copy-Item -Path "$NewAssemblyDir\$AssemblyName.dll" -Destination "$GACEquivalentPath\$AssemblyName.dll"
                }
            }
        }

        if ($Found.Count -lt 1) {
            Write-Error "Unable to find $AssemblyName.dll in any expected subdirectory paths within the zip file `"$NewAssemblyDir\$OutFileBaseName`"! Halting!"
            $global:FunctionResult = "1"
            return
        }
    }

    ##### END Main Body #####
}

function Load-Assemblies {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string[]]$AssemblyNames
    )

    ##### BEGIN Main Body #####
    [System.Collections.ArrayList]$ReferencedAssemblies = @()
    [System.Collections.ArrayList]$TypeDefUsingStatementsPrep = @()

    foreach ($assembly in $AssemblyNames) {
        $AssemblyInfo = Get-AssemblyAvailability -AssemblyName $assembly
        if (!$AssemblyInfo) {
            $global:FunctionResult = "0"
            Install-AssemblyViaNuGet -AssemblyName $assembly
            if ($global:FunctionResult -eq "1") {
                Write-Error "The Install-AssemblyViaNuGet function failed! Halting!"
                $global:FunctionResult = "1"
                return
            }

            $AssemblyInfo = Get-AssemblyAvailability -AssemblyName $assembly
            if (!$AssemblyInfo) {
                Write-Error "The assembly $assembly should be available, but isn't for some reason! Halting!"
                $global:FunctionResult = "1"
                return
            }
        }
        if ($AssemblyInfo) {
            if ($ReferencedAssemblies -notcontains $AssemblyInfo.FullName) {
                $null = $ReferencedAssemblies.Add($AssemblyInfo.FullName)
            }
        }

        $FinalUsingStatement = Get-AssemblyUsingStatement -AssemblyName $assembly -AssemblyFullInfo $AssemblyInfo -Silent
        if (!$FinalUsingStatement) {
            Write-Warning "Unable to create a valid `"using`" statement for assembly $assembly! Skipping..."
        }
        else {
            if ($TypeDefUsingStatementsPrep -notcontains $FinalUsingStatement) {
                $null = $TypeDefUsingStatementsPrep.Add($FinalUsingStatement)
            }
        }
    }

    $TypeDefUsingStatementsPrepAsString = $($TypeDefUsingStatementsPrep | Out-String).TrimEnd()
    
    New-Variable -Name "AddTypeParams" -Value $(
        [pscustomobject][ordered]@{
            ReferencedAssemblies            = $ReferencedAssemblies
            TypeDefinitionUsingStatements   = $TypeDefUsingStatementsPrepAsString
        }
    )
    
    $AddTypeParams

    ##### END main Body #####
}














































# SIG # Begin signature block
# MIIMLAYJKoZIhvcNAQcCoIIMHTCCDBkCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUQJCsy9hD2oN7RNK1yw5WXz5b
# z6ugggmhMIID/jCCAuagAwIBAgITawAAAAQpgJFit9ZYVQAAAAAABDANBgkqhkiG
# 9w0BAQsFADAwMQwwCgYDVQQGEwNMQUIxDTALBgNVBAoTBFpFUk8xETAPBgNVBAMT
# CFplcm9EQzAxMB4XDTE1MDkwOTA5NTAyNFoXDTE3MDkwOTEwMDAyNFowPTETMBEG
# CgmSJomT8ixkARkWA0xBQjEUMBIGCgmSJomT8ixkARkWBFpFUk8xEDAOBgNVBAMT
# B1plcm9TQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCmRIzy6nwK
# uqvhoz297kYdDXs2Wom5QCxzN9KiqAW0VaVTo1eW1ZbwZo13Qxe+6qsIJV2uUuu/
# 3jNG1YRGrZSHuwheau17K9C/RZsuzKu93O02d7zv2mfBfGMJaJx8EM4EQ8rfn9E+
# yzLsh65bWmLlbH5OVA0943qNAAJKwrgY9cpfDhOWiYLirAnMgzhQd3+DGl7X79aJ
# h7GdVJQ/qEZ6j0/9bTc7ubvLMcJhJCnBZaFyXmoGfoOO6HW1GcuEUwIq67hT1rI3
# oPx6GtFfhCqyevYtFJ0Typ40Ng7U73F2hQfsW+VPnbRJI4wSgigCHFaaw38bG4MH
# Nr0yJDM0G8XhAgMBAAGjggECMIH/MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBQ4uUFq5iV2t7PneWtOJALUX3gTcTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBR2
# lbqmEvZFA0XsBkGBBXi2Cvs4TTAxBgNVHR8EKjAoMCagJKAihiBodHRwOi8vcGtp
# L2NlcnRkYXRhL1plcm9EQzAxLmNybDA8BggrBgEFBQcBAQQwMC4wLAYIKwYBBQUH
# MAKGIGh0dHA6Ly9wa2kvY2VydGRhdGEvWmVyb0RDMDEuY3J0MA0GCSqGSIb3DQEB
# CwUAA4IBAQAUFYmOmjvbp3goa3y95eKMDVxA6xdwhf6GrIZoAg0LM+9f8zQOhEK9
# I7n1WbUocOVAoP7OnZZKB+Cx6y6Ek5Q8PeezoWm5oPg9XUniy5bFPyl0CqSaNWUZ
# /zC1BE4HBFF55YM0724nBtNYUMJ93oW/UxsWL701c3ZuyxBhrxtlk9TYIttyuGJI
# JtbuFlco7veXEPfHibzE+JYc1MoGF/whz6l7bC8XbgyDprU1JS538gbgPBir4RPw
# dFydubWuhaVzRlU3wedYMsZ4iejV2xsf8MHF/EHyc/Ft0UnvcxBqD0sQQVkOS82X
# +IByWP0uDQ2zOA1L032uFHHA65Bt32w8MIIFmzCCBIOgAwIBAgITWAAAADw2o858
# ZSLnRQAAAAAAPDANBgkqhkiG9w0BAQsFADA9MRMwEQYKCZImiZPyLGQBGRYDTEFC
# MRQwEgYKCZImiZPyLGQBGRYEWkVSTzEQMA4GA1UEAxMHWmVyb1NDQTAeFw0xNTEw
# MjcxMzM1MDFaFw0xNzA5MDkxMDAwMjRaMD4xCzAJBgNVBAYTAlVTMQswCQYDVQQI
# EwJWQTEPMA0GA1UEBxMGTWNMZWFuMREwDwYDVQQDEwhaZXJvQ29kZTCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ8LM3f3308MLwBHi99dvOQqGsLeC11p
# usrqMgmEgv9FHsYv+IIrW/2/QyBXVbAaQAt96Tod/CtHsz77L3F0SLuQjIFNb522
# sSPAfDoDpsrUnZYVB/PTGNDsAs1SZhI1kTKIjf5xShrWxo0EbDG5+pnu5QHu+EY6
# irn6C1FHhOilCcwInmNt78Wbm3UcXtoxjeUl+HlrAOxG130MmZYWNvJ71jfsb6lS
# FFE6VXqJ6/V78LIoEg5lWkuNc+XpbYk47Zog+pYvJf7zOric5VpnKMK8EdJj6Dze
# 4tJ51tDoo7pYDEUJMfFMwNOO1Ij4nL7WAz6bO59suqf5cxQGd5KDJ1ECAwEAAaOC
# ApEwggKNMA4GA1UdDwEB/wQEAwIHgDA9BgkrBgEEAYI3FQcEMDAuBiYrBgEEAYI3
# FQiDuPQ/hJvyeYPxjziDsLcyhtHNeIEnofPMH4/ZVQIBZAIBBTAdBgNVHQ4EFgQU
# a5b4DOy+EUyy2ILzpUFMmuyew40wHwYDVR0jBBgwFoAUOLlBauYldrez53lrTiQC
# 1F94E3EwgeMGA1UdHwSB2zCB2DCB1aCB0qCBz4aBq2xkYXA6Ly8vQ049WmVyb1ND
# QSxDTj1aZXJvU0NBLENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxD
# Tj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NlcnRp
# ZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmli
# dXRpb25Qb2ludIYfaHR0cDovL3BraS9jZXJ0ZGF0YS9aZXJvU0NBLmNybDCB4wYI
# KwYBBQUHAQEEgdYwgdMwgaMGCCsGAQUFBzAChoGWbGRhcDovLy9DTj1aZXJvU0NB
# LENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxD
# Tj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NBQ2VydGlmaWNhdGU/YmFz
# ZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0aG9yaXR5MCsGCCsGAQUFBzAC
# hh9odHRwOi8vcGtpL2NlcnRkYXRhL1plcm9TQ0EuY3J0MBMGA1UdJQQMMAoGCCsG
# AQUFBwMDMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYBBQUHAwMwDQYJKoZIhvcNAQEL
# BQADggEBACbc1NDl3NTMuqFwTFd8NHHCsSudkVhuroySobzUaFJN2XHbdDkzquFF
# 6f7KFWjqR3VN7RAi8arW8zESCKovPolltpp3Qu58v59qZLhbXnQmgelpA620bP75
# zv8xVxB9/xmmpOHNkM6qsye4IJur/JwhoHLGqCRwU2hxP1pu62NUK2vd/Ibm8c6w
# PZoB0BcC7SETNB8x2uKzJ2MyAIuyN0Uy/mGDeLyz9cSboKoG6aQibnjCnGAVOVn6
# J7bvYWJsGu7HukMoTAIqC6oMGerNakhOCgrhU7m+cERPkTcADVH/PWhy+FJWd2px
# ViKcyzWQSyX93PcOj2SsHvi7vEAfCGcxggH1MIIB8QIBATBUMD0xEzARBgoJkiaJ
# k/IsZAEZFgNMQUIxFDASBgoJkiaJk/IsZAEZFgRaRVJPMRAwDgYDVQQDEwdaZXJv
# U0NBAhNYAAAAPDajznxlIudFAAAAAAA8MAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRA4iVqmDqW
# eAGI5T8ulwkLeJpEqDANBgkqhkiG9w0BAQEFAASCAQCW7cEvjpLGgGdx605MWbJP
# JqqJLAZqek6WEwBnaWHd5blKuBtZoH5qiUZ6L353iG26xOfOTRe2kFO2RQMjw0Vz
# FDANfleGWFa+188iaILlGqNZ1fgxtCXUo4BYOXYk4ABf1Szv4jtJs9zcGM2E9MR4
# gDQoXcfz8vWCOTadH4yjL42EEjL9N0Jt/3GZoe794bkAFmTqjTrZw7w796Wq6VgC
# TI53M5T0ZaqPPOSgAshU5/0b/OGX5b5vvEslmH6b7rYIjf/UWELr4xP159j4E4FM
# SyIgy9Rd5bYz/zCcHpSitgWgd2AWOgHRL6A/HPAbK+ZGvoQP3pMx9/oMELPShs12
# SIG # End signature block
