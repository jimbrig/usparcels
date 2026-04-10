Function Test-SystemRAM {
  <#
  #>
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $false)]
    [int]$MinGB = 16,
    [Parameter(Mandatory = $false)]
    [int]$MaxGB = 32
  )

  $TotalRAM = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
  $TotalRAMGB = [math]::Round($TotalRAM / 1024 / 1024 / 1024, 2)
  Write-Output "Total system RAM: $TotalRAMGB GB"

  # get the RAM in use
  $RAMInUse = (Get-CimInstance -ClassName Win32_OperatingSystem).TotalVisibleMemorySize
  $RAMInUseGB = [math]::Round($RAMInUse / 1024 / 1024 / 1024, 2)
  Write-Output "RAM in use: $RAMInUseGB GB"

  # get the RAM available
  $RAMAvailable = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory
  $RAMAvailableGB = [math]::Round($RAMAvailable / 1024 / 1024 / 1024, 2)
  Write-Output "RAM available: $RAMAvailableGB GB"

  # get the RAM free
  $RAMFree = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory
  $RAMFreeGB = [math]::Round($RAMFree / 1024 / 1024 / 1024, 2)
  Write-Output "RAM free: $RAMFreeGB GB"

  # get the RAM used
  $RAMUsed = $RAMInUse - $RAMFree
  $RAMUsedGB = [math]::Round($RAMUsed / 1024 / 1024 / 1024, 2)
  Write-Output "RAM used: $RAMUsedGB GB"

  # get the RAM used percentage
  $RAMUsedPercentage = [math]::Round(($RAMUsed / $TotalRAM) * 100, 2)
  Write-Output "RAM used percentage: $RAMUsedPercentage%"

  # get the RAM available percentage
  $RAMAvailablePercentage = [math]::Round(($RAMAvailable / $TotalRAM) * 100, 2)
  Write-Output "RAM available percentage: $RAMAvailablePercentage%"

  # get the RAM free percentage
  $RAMFreePercentage = [math]::Round(($RAMFree / $TotalRAM) * 100, 2)
  Write-Output "RAM free percentage: $RAMFreePercentage%"
}