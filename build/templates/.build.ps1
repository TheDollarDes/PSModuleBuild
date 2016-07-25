﻿param (
	[string]$ReleaseNotes = $null
)

if (Test-Path '.\build\.buildenvironment.ps1') {
    . '.\build\.buildenvironment.ps1'
}
else {
    Write-Error "Without a build environment file we are at a loss as to what to do!"
}

# These are required for a full build process and will be automatically installed if they aren't available
$RequiredModules = @('PlatyPS')

# Some optional modules
if  ($OptionAnalyzeCode) {
    $RequiredModules += 'PSScriptAnalyzer'
}

if  ($OptionFormatCode ) {
    $RequiredModules += 'FormatPowershellCode'
}

# Public functions (to be exported by file name as the function name)
$PublicFunctionSource = 'src\public'

# Private function source
$PrivateFunctionSource = 'src\private'

# Other module source
$OtherModuleSource = 'src\other'

# Release directory. You typically want a module to reside in a folder of the same name in order to publish to psgallery
$BaseReleaseFolder = 'release'

# Build tool path (these scripts are dot sourced)
$BuildToolFolder = 'build'

# Scratch path - this is where all our scratch work occurs. It will be cleared out at every run.
$ScratchFolder = 'temp'

# You really shouldn't change this for a powershell module (if you want it to publish to the psgallery correctly)
$CurrentReleaseFolder = $ModuleToBuild

# Put together our full paths. Generally leave these alone
$ModuleFullPath = (Get-Item "$($ModuleToBuild).psm1").FullName
$ModuleManifestFullPath = (Get-Item "$($ModuleToBuild).psd1").FullName
$ScriptRoot = Split-Path $ModuleFullPath
$ScratchPath = Join-Path $ScriptRoot $ScratchFolder
$ReleasePath = Join-Path $ScriptRoot $BaseReleaseFolder
$CurrentReleasePath = Join-Path $ReleasePath $CurrentReleaseFolder

$StageReleasePath = Join-Path $ScratchPath $BaseReleaseFolder   # Just before releasing the module we stage some changes in this location.
$ReleaseModule = "$($StageReleasePath)\$($ModuleToBuild).psm1"

# Additional build scripts and tools are found here (note that any dot sourced functions must be scoped at the script level)
$BuildToolPath = Join-Path $ScriptRoot $BuildToolFolder

# The required file containing our current working build version
$VersionFile = "$($ScriptRoot)\version.txt"

# Used later to determine if we are in a configured state or not
$IsConfigured = $False

# Used to update our function CBH to external help reference
$ExternalHelp = @"
<#
    .EXTERNALHELP $($ModuleToBuild)-help.xml
    #>
"@

#Synopsis: Validate system requirements are met
task ValidateRequirements {
    Write-Host -NoNewLine '      Running Powershell version 5?'
    assert ($PSVersionTable.PSVersion.Major.ToString() -eq '5') 'Powershell 5 is required for this build to function properly (you can comment this assert out if you are able to work around this requirement)'
    Write-Host -ForegroundColor Green '...Yup!'
}

#Synopsis: Load required modules if available. Otherwise try to install, then load it.
task LoadRequiredModules {
    $RequiredModules | Foreach {
        if ((get-module $_ -ListAvailable) -eq $null) {
            Write-Host -NoNewLine "      Installing $($_) Module"
            $null = Install-Module $_
            Write-Host -ForegroundColor Green '...Installed!'
        }
        if (get-module $_ -ListAvailable) {
            Write-Host -NoNewLine "      Importing $($_) Module"
            Import-Module $_ -Force
            Write-Host -ForegroundColor Green '...Loaded!'
        }
        else {
            throw 'How did you even get here?'
        }
    }
}

#Synopsis: Load dot sourced functions into this build session
task LoadBuildTools {
    # Dot source any build script functions we need to use
    Get-ChildItem $BuildToolPath/dotSource -Recurse -Filter "*.ps1" -File | Foreach { 
        Write-Output "      Dot sourcing script file: $($_.Name)"
        . $_.FullName
    }
}

# Synopsis: Create new module manifest
task CreateModuleManifest -After CreateModulePSM1 {
    $PSD1OutputFile = "$($StageReleasePath)\$($ModuleToBuild).psd1"
    Write-Host -NoNewLine "      Attempting to create a new module manifest file:  $PSD1OutputFile"
    #Replace-FileString -Pattern "PrivateData = ''"  $NewPrivateDataString $StageReleasePath\$ModuleToBuild.psd1 -Overwrite -Encoding 'UTF8'
    $OldManifest = Get-Content -Path $ModuleManifestFullPath -Raw
    if ($OldManifest -match "FunctionsToExport = \'\*\'") {
        $NewFunctionsToExport =  "FunctionsToExport = " + ((Convert-ArrayToString $Script:FunctionsToExport -Flatten) -replace '@\(','' -replace '\)','')
        $OldManifest -replace "FunctionsToExport = \'\*\'",$NewFunctionsToExport | Out-File -FilePath $PSD1OutputFile -force -Encoding:utf8
    }
    else {
        Write-Error "Unable to find the FunctionsToExport = '*' in the manifest file :("
    }
    Write-Host -ForegroundColor Green '...Loaded!'
}

# Synopsis: Load the module project
task LoadModule {
    Write-Host -NoNewLine '      Attempting to load the project module.'
    try {
        #$Script:Module = Import-Module $ModuleManifestFullPath -Force -PassThru
        $Script:Module = Import-Module $ModuleFullPath -Force -PassThru
        #$Script:ModuleManifest =  Test-ModuleManifest $ModuleManifestFullPath
        Write-Host -ForegroundColor Green '...Loaded!'
    }
    catch {
        throw "Unable to load the project module: $($ModuleFullPath)"
    }
}

# Synopsis: Import the current module manifest file for processing
task LoadModuleManifest {
    assert (test-path $ModuleManifestFullPath) "Unable to locate the module manifest file: $ModuleManifestFullPath"

    Write-Host -NoNewLine '      Loading the existing module manifest for this module'
    $Script:Manifest = Import-PowerShellDataFile -Path $ModuleManifestFullPath
    Write-Host -ForegroundColor Green '...Loaded!'
}

# Synopsis: Set $script:Version.
task Version {
    $Script:Version = [version](Get-Content $VersionFile)
    
    Write-Host -NoNewLine '      Manifest version and the release version (version.txt) are the same?'
    assert ( ($Script:Manifest).ModuleVersion.ToString() -eq (($Script:Version).ToString())) "The module manifest version ( $($($Script:Manifest).ModuleVersion.ToString()) ) and release version ($($Script:Version)) are mismatched. These must be the same before continuing. Consider running the UpdateVersion task to make the module manifest version the same as the reslease version."
    Write-Host -ForegroundColor Green '...Yup!'
}

#Synopsis: Validate script requirements are met, load required modules, load project manifest and module, and load additional build tools.
task Configure ValidateRequirements, LoadRequiredModules, LoadModuleManifest, LoadModule, Version, LoadBuildTools, {
    # If we made it this far then we are configured!
    $Script:IsConfigured = $True
    Write-Host -NoNewline '      Configure build environment'
    Write-Host -ForegroundColor Green '...configured!'
}

# Synopsis: Update current module manifest with the version defined in version.txt if they differ
task UpdateVersion LoadBuildTools, LoadModuleManifest, LoadModule, (job Version -Safe), {
    assert ($Script:Version -ne $null) 'Unable to pull a version from version.txt!'
    if (error Version) {
        $ModVer = .{switch -Regex -File $ModuleManifestFullPath {"ModuleVersion\s+=\s+'(\d+\.\d+\.\d+)'" {return $Matches[1]}}}
        if ($ModVer -ne $null) {
            Write-Host -NoNewline "      Attempting to update the module manifest version ($ModVer) to $(($Script:Version).ToString())"
            $NewManifestVersion = "ModuleVersion = '" + $Script:Version + "'"
            Replace-FileString -Pattern "ModuleVersion\s+=\s+'\d+\.\d+\.\d+'" $NewManifestVersion $ModuleManifestFullPath -Overwrite
            Write-Host -ForegroundColor Green '...Updated!'
        }
        else {
            throw 'The module manifest file does not seem to contain a ModuleVersion directive!'
        }
    }
    else {
        Write-Output '      Module manifest version and version found in version.txt are already the same.'
    }
}

# Synopsis: Remove/regenerate scratch staging directory
task Clean {
	$null = Remove-Item $ScratchPath -Force -Recurse -ErrorAction 0
    $null = New-Item $ScratchPath -ItemType:Directory
    Write-Host -NoNewLine "      Clean up our scratch/staging directory at $($ScratchPath)" 
    Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Create base content tree in scratch staging area
task PrepareStage {
    # Create the directories
    $null = New-Item "$($ScratchPath)\src" -ItemType:Directory -Force
    $null = New-Item $StageReleasePath -ItemType:Directory -Force

    Copy-Item -Path "$($ScriptRoot)\*.psm1" -Destination $ScratchPath
    Copy-Item -Path "$($ScriptRoot)\*.psd1" -Destination $ScratchPath
    Copy-Item -Path "$($ScriptRoot)\$($PublicFunctionSource)" -Recurse -Destination "$($ScratchPath)\$($PublicFunctionSource)"
    Copy-Item -Path "$($ScriptRoot)\$($PrivateFunctionSource)" -Recurse -Destination "$($ScratchPath)\$($PrivateFunctionSource)"
    Copy-Item -Path "$($ScriptRoot)\$($OtherModuleSource)" -Recurse -Destination "$($ScratchPath)\$($OtherModuleSource)"
    Copy-Item -Path "$($ScriptRoot)\en-US" -Recurse -Destination $ScratchPath
    $Script:AdditionalModulePaths | ForEach {
        Copy-Item -Path $_ -Recurse -Destination $ScratchPath -Force
    }
}

# Synopsis:  Collect a list of our public methods for later module manifest updates
task GetPublicFunctions {
    $Exported = @()
    Get-ChildItem "$($ScriptRoot)\$($PublicFunctionSource)" -Recurse -Filter "*.ps1" -File | Sort-Object Name | Foreach { 
       $Exported += ([System.Management.Automation.Language.Parser]::ParseInput((Get-Content -Path $_.FullName -Raw), [ref]$null, [ref]$null)).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | Foreach {$_.Name}
    }
    # $Script:FunctionsToExport = (Get-ChildItem -Path $ScriptRoot\$($PublicFunctionSource)).BaseName | foreach {$_.ToString()}
    if ($Exported.Count -eq 0) {
        Write-Error 'There are no public functions to export!'
    }
    $Script:FunctionsToExport = $Exported
    Write-Host "      Number of exported functions found = $($Exported.Count)"
    Write-Host -NoNewLine '      Parsing for public (exported) function names'
    Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Assemble the module for release
task CreateModulePSM1 {
    if ($Script:OptionCombineFiles) {
        $CombineFiles = "## Pre-Loaded Module code ##`r`n`r`n"
        Write-Host "      Other Source Files: $($ScratchPath)\$($OtherModuleSource)"
        Get-childitem  (Join-Path $ScratchPath "$($OtherModuleSource)\PreLoad.ps1") | foreach {
            Write-Host "             $($_.Name)"
            $CombineFiles += (Get-content $_ -Raw) + "`r`n`r`n"
        }
        Write-Host -NoNewLine "      Combining preload source"
        Write-Host -ForegroundColor Green '...Complete!'

        $CombineFiles += "## PRIVATE MODULE FUNCTIONS AND DATA ##`r`n`r`n"
        Write-Host  "      Private Source Files: $($ScratchPath)\$($PrivateFunctionSource)"
        Get-childitem  (Join-Path $ScratchPath "$($PrivateFunctionSource)\*.ps1") | foreach {
            Write-Host "             $($_.Name)"
            $CombineFiles += (Get-content $_ -Raw) + "`r`n`r`n"
        }
        Write-Host -NoNewLine "      Combining private source files"
        Write-Host -ForegroundColor Green '...Complete!'

        $CombineFiles += "## PUBLIC MODULE FUNCTIONS AND DATA ##`r`n`r`n"
        Write-Host  "      Public Source Files: $($PublicFunctionSource)"
        Get-childitem  (Join-Path $ScratchPath "$($PublicFunctionSource)\*.ps1") | foreach {
            Write-Host "             $($_.Name)"
            $CombineFiles += (Get-content $_ -Raw) + "`r`n`r`n"
        }
        Write-Host -NoNewline "      Combining public source files"
        Write-Host -ForegroundColor Green '...Complete!'
        $CombineFiles += "## Post-Load Module code ##`r`n`r`n"
        Write-Host "      Other Source Files: $($ScratchPath)\$($OtherModuleSource)"
        Get-childitem  (Join-Path $ScratchPath "$($OtherModuleSource)\PostLoad.ps1") | foreach {
            Write-Host "             $($_.Name)"
            $CombineFiles += (Get-content $_ -Raw) + "`r`n`r`n"
        }
        Write-Host -NoNewLine "      Combining postload source"
        Write-Host -ForegroundColor Green '...Complete!'
    
        Set-Content -Path $Script:ReleaseModule  -Value $CombineFiles -Encoding UTF8
        Write-Host -NoNewLine '      Combining module functions and data into one PSM1 file'
        Write-Host -ForegroundColor Green '...Complete!'
    }
    else {
        Copy-Item -Path (Join-Path $ScratchPath $OtherModuleSource) -Recurse -Destination $StageReleasePath -Force
        Copy-Item -Path (Join-Path $ScratchPath $PrivateFunctionSource) -Recurse -Destination $StageReleasePath -Force
        Copy-Item -Path (Join-Path $ScratchPath $PublicFunctionSource) -Recurse -Destination $StageReleasePath -Force
        Copy-Item -Path (Join-Path $ScratchPath $ModuleToBuild) -Destination $StageReleasePath -Force
        Write-Host -NoNewLine '      Copy over source and psm1 files'
        Write-Host -ForegroundColor Green '...Complete!'
    }

    $Script:AdditionalModulePaths | ForEach {
        Copy-Item -Path $_ -Recurse -Destination $StageReleasePath -Force
    }
}

# Synopsis: Warn about not empty git status if .git exists.
task GitStatus -If (Test-Path .git) {
	$status = exec { git status -s }
	if ($status) {
		Write-Warning "      Git status: $($status -join ', ')"
	}
}

# Synopsis: Run code formatter against our working build (dogfood).
task FormatCode -if {$OptionFormatCode} {
        Get-ChildItem -Path $ScratchPath -Include "*.ps1","*.psm1" -Recurse -File | Where {$_.FullName -notlike "$($StageReleasePath)*"} | ForEach {
            $FormattedOutFile = $_.FullName
            Write-Output "      Formatting File: $($FormattedOutFile)"
            $FormattedCode = get-content $_ -raw |
                Format-ScriptRemoveStatementSeparators |
                Format-ScriptExpandFunctionBlocks |
                Format-ScriptExpandNamedBlocks |
                Format-ScriptExpandParameterBlocks |
                Format-ScriptExpandStatementBlocks |
                Format-ScriptPadOperators |
                Format-ScriptPadExpressions |
                Format-ScriptFormatTypeNames |
                Format-ScriptReduceLineLength |
                Format-ScriptRemoveSuperfluousSpaces |
                Format-ScriptFormatCodeIndentation

                $FormattedCode | Out-File -FilePath $FormattedOutFile -force -Encoding:utf8
        }
        Write-Host ''
        Write-Host -NoNewLine '      Reformat script files'
        Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Replace comment based help with external help in all public functions for this project
task UpdateCBH -Before CreateModulePSM1 {
    $CBHPattern = "(?ms)(\<#.*\.SYNOPSIS.*?#>)"
    Get-ChildItem -Path "$($ScratchPath)\$($PublicFunctionSource)\*.ps1" -File | ForEach {
            $FormattedOutFile = $_.FullName
            Write-Output "      Replacing CBH in file: $($FormattedOutFile)"
            $UpdatedFile = (get-content  $FormattedOutFile -raw) -replace $CBHPattern, $ExternalHelp
            $UpdatedFile | Out-File -FilePath $FormattedOutFile -force -Encoding:utf8
    }
}

# Synopsis: Run PSScriptAnalyzer against the assembled module
task AnalyzeScript -After CreateModulePSM1 -if {$OptionAnalyzeCode} {
    $Analysis = Invoke-ScriptAnalyzer -Path $StageReleasePath
    $AnalysisErrors = @($Analysis | Where-Object {@('Information','Warning') -notcontains $_.Severity})

    if ($AnalysisErrors.Count -ne 0) {
        throw 'Script Analysis came up with some errors!'
    }
    
    Write-Host -NoNewLine '      Analyzing script module' 
    Write-Host -ForegroundColor Green '...Complete!'
    $AnalysisWarnings = @($Analysis | Where-Object {$_.Severity -eq 'Warning'})
    $AnalysisInfo =  @($Analysis | Where-Object {$_.Severity -eq 'Information'})
    Write-Host -ForegroundColor Yellow "          Script Analysis Warnings = $($AnalysisWarnings.Count)" 
    Write-Host "          Script Analysis Informational = $($AnalysisInfo.Count)"
}

# Synopsis: Build help files for module
task CreateHelp CreateMarkdownHelp, CreateExternalHelp, CreateUpdateableHelpCAB, {
    Write-Host -NoNewLine '      Create help files' 
    Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Build help files for module and ignore missing section errors
task TestCreateHelp Configure, CreateMarkdownHelp, CreateExternalHelp, CreateUpdateableHelpCAB,  {
    Write-Host -NoNewLine '      Create help files' 
    Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Build the markdown help files with PlatyPS
task CreateMarkdownHelp GetPublicFunctions, {
    # First copy over documentation
    Copy-Item -Path "$($ScratchPath)\en-US" -Recurse -Destination $StageReleasePath -Force

    $OnlineModuleLocation = "$($ModuleWebsite)/$($BaseReleaseFolder)"
    $FwLink = "$($OnlineModuleLocation)/$($CurrentReleaseFolder)/docs/$($ModuleToBuild).md"
    $ModulePage = "$($StageReleasePath)\docs\$($ModuleToBuild).md"
    
    # Create the .md files and the generic module page md as well
    $null = New-MarkdownHelp -module $ModuleToBuild -OutputFolder "$($StageReleasePath)\docs\" -Force -WithModulePage -Locale 'en-US' -FwLink $FwLink -HelpVersion $Script:Version

    # Replace each missing element we need for a proper generic module page .md file
    $ModulePageFileContent = Get-Content -raw $ModulePage
    $ModulePageFileContent = $ModulePageFileContent -replace '{{Manually Enter Description Here}}', $Script:Manifest.Description
    $Script:FunctionsToExport | Foreach-Object {
        Write-Host "      Updating definition for the following function: $($_)"
        $TextToReplace = "{{Manually Enter $($_) Description Here}}"
        $ReplacementText = (Get-Help -Detailed $_).Synopsis
        $ModulePageFileContent = $ModulePageFileContent -replace $TextToReplace, $ReplacementText
    }
    $ModulePageFileContent | Out-File $ModulePage -Force -Encoding:utf8

    $MissingDocumentation = Select-String -Path "$($StageReleasePath)\docs\*.md" -Pattern "({{.*}})"
    if ($MissingDocumentation.Count -gt 0) {
        Write-Host -ForegroundColor Yellow ''
        Write-Host -ForegroundColor Yellow '   The documentation that got generated resulted in missing sections which should be filled out.'
        Write-Host -ForegroundColor Yellow '   Please review the following sections in your comment based help, fill out missing information and rerun this build:'
        Write-Host -ForegroundColor Yellow '   (Note: This can happen if the .EXTERNALHELP CBH is defined for a function before running this build.)'
        Write-Host ''
        Write-Host -ForegroundColor Yellow "Path of files with issues: $($StageReleasePath)\docs\"
        Write-Host ''
        $MissingDocumentation | Select FileName,Matches | ft -auto
        Write-Host -ForegroundColor Yellow ''
        pause

        throw 'Missing documentation. Please review and rebuild.'
    }

    Write-Host -NoNewLine '      Creating markdown documentation with PlatyPS'
    Write-Host -ForegroundColor Green '...Complete!'
}

# Synopsis: Build the markdown help files with PlatyPS
task CreateExternalHelp {
    Write-Host -NoNewLine '      Creating markdown help files'
    $null = New-ExternalHelp "$($StageReleasePath)\docs" -OutputPath "$($StageReleasePath)\en-US\" -Force
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Build the help file CAB with PlatyPS
task CreateUpdateableHelpCAB {
    Write-Host -NoNewLine "      Creating updateable help cab file"
    $LandingPage = "$($StageReleasePath)\docs\$($ModuleToBuild).md"
    $null = New-ExternalHelpCab -CabFilesFolder "$($StageReleasePath)\en-US\" -LandingPagePath $LandingPage -OutputFolder "$($StageReleasePath)\en-US\"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Create a new version release directory for our release and copy our contents to it
task PushVersionRelease {
    $ThisReleasePath = Join-Path $ReleasePath $Script:Version
    $null = Remove-Item $ThisReleasePath -Force -Recurse -ErrorAction 0
    $null = New-Item $ThisReleasePath -ItemType:Directory -Force
    Copy-Item -Path "$($StageReleasePath)\*" -Destination $ThisReleasePath -Recurse
    Out-Zip $StageReleasePath $ReleasePath\$ModuleToBuild'-'$Version'.zip' -overwrite
    Write-Host -NoNewLine "      Pushing a version release to $($ThisReleasePath)"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Create the current release directory and copy this build to it.
task PushCurrentRelease {
    $null = Remove-Item $CurrentReleasePath -Force -Recurse -ErrorAction 0
    $null = New-Item $CurrentReleasePath -ItemType:Directory -Force
    Copy-Item -Path "$($StageReleasePath)\*" -Destination $CurrentReleasePath -Recurse -force
    Out-Zip $StageReleasePath $ReleasePath\$ModuleToBuild'-current.zip' -overwrite
    Write-Host -NoNewLine "      Pushing a version release to $($CurrentReleasePath)"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Push with a version tag.
task GitPushRelease Version, {
	$changes = exec { git status --short }
	assert (-not $changes) "Please, commit changes."

	exec { git push }
	exec { git tag -a "v$($Script:Version)" -m "v$($Script:Version)" }
	exec { git push origin "v$($Script:Version)" }
}

# Synopsis: Push to github
task GithubPush Version, {
    exec { git add . }
    if ($ReleaseNotes -ne $null) {
        exec { git commit -m "$ReleaseNotes"}
    }
    else {
        exec { git commit -m "$($Script:Version)"}
    }
    exec { git push origin master }
	$changes = exec { git status --short }
	assert (-not $changes) "Please, commit changes."
}

# Synopsis: Create a new .psgallery project profile file (.psgallery)
task NewPSGalleryProfile Configure, {
    $PSGallaryParams = @{}
    $PSGallaryParams.Path = "$($CurrentReleasePath)"
    $PSGallaryParams.ProjectUri = $ModuleWebsite
    If ($ReleaseNotes -ne $null) {
        $PSGallaryParams.ReleaseNotes = $ReleaseNotes
    }
    
    # Update our gallary data with any tags from the manifest file (if they exist)
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'Tags') {
        $PSGallaryParams.Tags  = ($Script:Manifest.PrivateData.PSData.Tags | Foreach {$_}) -join ','
    }
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'LicenseUri') {
        if ($Script:Manifest.PrivateData.PSData.LicenseUri -ne $null) {
            $PSGallaryParams.LicenseUri = $Script:Manifest.PrivateData.PSData.LicenseUri
        }
    }
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'IconUri') {
        if ($Script:Manifest.PrivateData.PSData.IconUri -ne $null) {
            $PSGallaryParams.IconUri = $Script:Manifest.PrivateData.PSData.IconUri
        }
    }

    New-PSGalleryProjectProfile @PSGallaryParams
    Write-Host -NoNewLine "      Updating .psgallery profile"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Update the psgallery project profile data file
task UpdatePSGalleryProfile Configure, {
    $PSGallaryParams = @{}
    $PSGallaryParams.Path = "$($CurrentReleasePath)"
    $PSGallaryParams.ProjectUri = $ModuleWebsite
    If ($ReleaseNotes -ne $null) {
        $PSGallaryParams.ReleaseNotes = $ReleaseNotes
    }
    
    # Update our gallary data with any tags from the manifest file (if they exist)
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'Tags') {
        $PSGallaryParams.Tags  = ($Script:Manifest.PrivateData.PSData.Tags | Foreach {$_}) -join ','
    }
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'LicenseUri') {
        if ($Script:Manifest.PrivateData.PSData.LicenseUri -ne $null) {
            $PSGallaryParams.LicenseUri = $Script:Manifest.PrivateData.PSData.LicenseUri
        }
    }
    if ( $Script:Manifest.PrivateData.PSdata.Keys -contains 'IconUri') {
        if ($Script:Manifest.PrivateData.PSData.IconUri -ne $null) {
            $PSGallaryParams.IconUri = $Script:Manifest.PrivateData.PSData.IconUri
        }
    }

    Update-PSGalleryProjectProfile @PSGallaryParams
    Write-Host -NoNewLine "      Updating .psgallery profile"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Push the project to PSScriptGallery
task PublishPSGallery UpdatePSGalleryProfile, {
    Upload-ProjectToPSGallery
    Write-Host -NoNewLine "      Uploading project to PSGallery"
    Write-Host -ForeGroundColor green '...Complete!'
}

# Synopsis: Remove session artifacts like loaded modules and variables
task BuildSessionCleanup {
    # Clean up loaded modules if they are loaded
    $RequiredModules | Foreach {
        Write-Output "      Removing $($_) module (if loaded)."
        Remove-Module $_  -Erroraction Ignore
    }
    Write-Output "      Removing $ModuleToBuild module  (if loaded)."
    Remove-Module $ModuleToBuild -Erroraction Ignore
}

# Synopsis: The default build
task . `
        Configure, 
	    Clean, 
        PrepareStage, 
        GetPublicFunctions,
        FormatCode,
        CreateHelp,
        CreateModulePSM1, 
        PushVersionRelease, 
        PushCurrentRelease, 
        BuildSessionCleanup

# Synopsis: Build without code formatting
task BuildWithoutCodeFormatting `
        Configure, 
	    Clean, 
        PrepareStage,
        GetPublicFunctions,
        CreateHelp,
        CreateModulePSM1, 
        PushVersionRelease, 
        PushCurrentRelease, 
        BuildSessionCleanup

# Synopsis: Test the code formatting module only
task TestCodeFormatting Configure, Clean, PrepareStage, GetPublicFunctions, FormatCode

# Synopsis: Build help files for module and ignore missing section errors
task TestCreateHelp Configure, CreateMarkdownHelp, CreateExternalHelp, CreateUpdateableHelpCAB