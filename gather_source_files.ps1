[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryUrl = 'https://github.com/ImGuiNET/ImGui.NET-nativebuild'

function Test-CommandExists {
	param(
		[Parameter(Mandatory = $true)]
		[string]$CommandName
	)

	return $null -ne (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
}

function Copy-RelativeFile {
	param(
		[Parameter(Mandatory = $true)]
		[string]$SourceRoot,

		[Parameter(Mandatory = $true)]
		[string]$DestinationRoot,

		[Parameter(Mandatory = $true)]
		[string]$RelativePath,

		[switch]$Optional
	)

	$sourcePath = Join-Path -Path $SourceRoot -ChildPath $RelativePath
	if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
		if ($Optional) {
			Write-Verbose "Skipping optional file: $RelativePath"
			return
		}

		throw "Required file not found: $RelativePath"
	}

	$destinationPath = Join-Path -Path $DestinationRoot -ChildPath $RelativePath
	$destinationDirectory = Split-Path -Path $destinationPath -Parent
	if (-not (Test-Path -LiteralPath $destinationDirectory)) {
		New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
	}

	Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Get-ConfigValue {
	param(
		[Parameter(Mandatory = $true)]
		[psobject]$Config,

		[Parameter(Mandatory = $true)]
		[string]$PropertyName,

		$DefaultValue
	)

	$property = $Config.PSObject.Properties[$PropertyName]
	if ($null -eq $property) {
		return $DefaultValue
	}

	if ($null -eq $property.Value) {
		return $DefaultValue
	}

	return $property.Value
}

if (-not (Test-CommandExists -CommandName 'git')) {
	throw 'git is required but was not found in PATH.'
}

$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
	throw "Config file not found: $resolvedConfigPath"
}

$configDirectory = Split-Path -Path $resolvedConfigPath -Parent

try {
	$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
}
catch {
	throw "Failed to parse config JSON: $resolvedConfigPath. $($_.Exception.Message)"
}

$sha = Get-ConfigValue -Config $config -PropertyName 'Sha' -DefaultValue $null
$outputZipPath = Get-ConfigValue -Config $config -PropertyName 'OutputZipPath' -DefaultValue (Join-Path -Path $configDirectory -ChildPath 'cimgui-source-package.zip')
$force = [bool](Get-ConfigValue -Config $config -PropertyName 'Force' -DefaultValue $false)
$keepWorkingDirectories = [bool](Get-ConfigValue -Config $config -PropertyName 'KeepWorkingDirectories' -DefaultValue $false)

$resolvedOutputZipPath = $outputZipPath
if (-not [System.IO.Path]::IsPathRooted($resolvedOutputZipPath)) {
	$resolvedOutputZipPath = Join-Path -Path $configDirectory -ChildPath $resolvedOutputZipPath
}
$resolvedOutputZipPath = [System.IO.Path]::GetFullPath($resolvedOutputZipPath)
if ((Test-Path -LiteralPath $resolvedOutputZipPath) -and -not $force) {
	throw "Output zip already exists: $resolvedOutputZipPath. Use -Force to overwrite it."
}

$workRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString('N'))
$cloneRoot = Join-Path -Path $workRoot -ChildPath 'repo'
$stagingRoot = Join-Path -Path $workRoot -ChildPath 'staging'
$packageRoot = $stagingRoot

$filesToCopy = @(
	'build-native.cmd',
	'build-native.sh',
	'cimgui/CMakeLists.txt',
	'cimgui/LICENSE',
	'cimgui/cimgui.cpp',
	'cimgui/cimgui.h',
	'cimgui/cimconfig.h',
	'cimgui/imgui/LICENSE.txt',
	'cimgui/imgui/imconfig.h',
	'cimgui/imgui/imgui.cpp',
	'cimgui/imgui/imgui.h',
	'cimgui/imgui/imgui_demo.cpp',
	'cimgui/imgui/imgui_draw.cpp',
	'cimgui/imgui/imgui_internal.h',
	'cimgui/imgui/imgui_tables.cpp',
	'cimgui/imgui/imgui_widgets.cpp',
	'cimgui/imgui/imstb_rectpack.h',
	'cimgui/imgui/imstb_textedit.h',
	'cimgui/imgui/imstb_truetype.h'
)

try {
	New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null
	New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

	$cloneArguments = @(
		'clone',
		'--recurse-submodules'
	)

	if (-not $sha) {
		$cloneArguments += @(
			'--shallow-submodules',
			'--depth',
			'1'
		)
	}

	$cloneArguments += @($repositoryUrl, $cloneRoot)

	Write-Host "Cloning $repositoryUrl ..."
	& git @cloneArguments
	if ($LASTEXITCODE -ne 0) {
		throw 'git clone failed.'
	}

	if ($sha) {
		Write-Host "Checking out commit $sha ..."
		& git -C $cloneRoot checkout --detach $sha
		if ($LASTEXITCODE -ne 0) {
			throw "Failed to check out commit: $sha"
		}

		& git -C $cloneRoot submodule update --init --recursive
		if ($LASTEXITCODE -ne 0) {
			throw 'Failed to update submodules after checking out the requested commit.'
		}
	}

	foreach ($relativePath in $filesToCopy) {
		Copy-RelativeFile -SourceRoot $cloneRoot -DestinationRoot $packageRoot -RelativePath $relativePath -Optional:($relativePath -eq 'cimgui/imgui/imgui_tables.cpp')
	}

	$sourceCommit = (& git -C $cloneRoot rev-parse HEAD).Trim()
	if ($LASTEXITCODE -ne 0) {
		throw 'Failed to resolve source commit.'
	}

	$submoduleCommit = (& git -C (Join-Path -Path $cloneRoot -ChildPath 'cimgui') rev-parse HEAD).Trim()
	if ($LASTEXITCODE -ne 0) {
		throw 'Failed to resolve cimgui submodule commit.'
	}

	$manifestLines = @(
		"RepositoryUrl=$repositoryUrl",
		"ConfigPath=$resolvedConfigPath",
		"RequestedSha=$sha",
		"RepositoryCommit=$sourceCommit",
		"CimguiCommit=$submoduleCommit",
		'IncludedFiles=',
		$filesToCopy | ForEach-Object { "  $_" }
	)

	$manifestPath = Join-Path -Path $packageRoot -ChildPath 'package-manifest.txt'
	Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding ascii

	if (Test-Path -LiteralPath $resolvedOutputZipPath) {
		Remove-Item -LiteralPath $resolvedOutputZipPath -Force
	}

	$archiveInputs = Get-ChildItem -LiteralPath $packageRoot -Force | ForEach-Object {
		$_.FullName
	}
	if ($archiveInputs.Count -eq 0) {
		throw 'No files were staged for archiving.'
	}

	Write-Host "Creating $resolvedOutputZipPath ..."
	Compress-Archive -LiteralPath $archiveInputs -DestinationPath $resolvedOutputZipPath -CompressionLevel Optimal

	Write-Host 'Archive created successfully.'
	Write-Host "Zip: $resolvedOutputZipPath"
}
finally {
	if (-not $keepWorkingDirectories -and (Test-Path -LiteralPath $workRoot)) {
		Remove-Item -LiteralPath $workRoot -Recurse -Force
	}
}
