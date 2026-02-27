<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
         xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- ================================================================== -->
  <!-- Pass 1: windowsPE — Runs during Windows Setup (before install)     -->
  <!-- ================================================================== -->
  <settings pass="windowsPE">

    <!-- Locale -->
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <!-- VirtIO storage driver (required to see the disk)
         Drive letter for the VirtIO CD-ROM varies depending on boot order,
         so we brute-force D:, E:, F: for both w11 and 2k22 driver paths. -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>D:\amd64\w11</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\amd64\w11</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>F:\amd64\w11</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4">
          <Path>D:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5">
          <Path>E:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6">
          <Path>F:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7">
          <Path>D:\NetKVM\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8">
          <Path>E:\NetKVM\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9">
          <Path>F:\NetKVM\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10">
          <Path>D:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11">
          <Path>E:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12">
          <Path>F:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="13">
          <Path>D:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="14">
          <Path>E:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="15">
          <Path>F:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>

    <!-- Disk & image selection -->
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Active>true</Active>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <!-- Index 1 = Standard Evaluation (Server Core, no GUI)
                   Index 2 = Standard Evaluation (Desktop Experience)
                   Desktop Experience is required: Astroneer's UE4 server binary
                   links against DirectX, DirectSound, OpenGL32 etc., which are
                   absent in Server Core. -->
              <Key>/IMAGE/INDEX</Key>
              <Value>2</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
        <!-- No ProductKey — the evaluation ISO supplies its own.
             A KMS/GVLK key here would cause "key does not match any image"
             because the evaluation edition is a different SKU. -->
      </UserData>
    </component>
  </settings>

  <!-- ================================================================== -->
  <!-- Pass 4: specialize — Runs after image is applied                   -->
  <!-- ================================================================== -->
  <settings pass="specialize">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ComputerName>AstroServer</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <!-- Suppress Server Manager auto-launch -->
    <component name="Microsoft-Windows-ServerManager-SvrMgrNc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
    </component>

    <!-- Load remaining VirtIO drivers -->
    <component name="Microsoft-Windows-PnpCustomizationsNonWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>D:\Balloon\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\Balloon\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>F:\Balloon\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4">
          <Path>D:\vioserial\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5">
          <Path>E:\vioserial\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6">
          <Path>F:\vioserial\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7">
          <Path>D:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8">
          <Path>E:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9">
          <Path>F:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10">
          <Path>D:\vioserial\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11">
          <Path>E:\vioserial\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12">
          <Path>F:\vioserial\2k22\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>

  <!-- ================================================================== -->
  <!-- Pass 7: oobeSystem — First boot / OOBE                            -->
  <!-- ================================================================== -->
  <settings pass="oobeSystem">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <AdministratorPassword>
          <Value>@@WIN_PASSWORD@@</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>@@WIN_PASSWORD@@</Value>
              <PlainText>true</PlainText>
            </Password>
            <Group>Administrators</Group>
            <DisplayName>@@WIN_USERNAME@@</DisplayName>
            <Name>@@WIN_USERNAME@@</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>@@WIN_USERNAME@@</Username>
        <Password>
          <Value>@@WIN_PASSWORD@@</Value>
          <PlainText>true</PlainText>
        </Password>
        <!-- Autologon only needed for initial provisioning;
             the Astroneer server auto-starts from the Startup folder -->
        <LogonCount>10</LogonCount>
      </AutoLogon>

      <!-- ============================================================ -->
      <!-- FirstLogonCommands — Install OpenSSH, then signal readiness   -->
      <!-- ============================================================ -->
      <FirstLogonCommands>

        <!-- 1. Install OpenSSH Server -->
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Install OpenSSH Server</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 2. Start sshd -->
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Start SSH server</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Start-Service sshd"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 3. Set sshd to start automatically -->
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Set SSH to auto-start</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Set-Service -Name sshd -StartupType Automatic"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 4. Set PowerShell as default SSH shell -->
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Set PowerShell as default SSH shell</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 5. Ensure SSH firewall rule exists -->
        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Allow SSH through firewall</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "if (!(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 6. Enable full admin rights over SSH (disable UAC remote token filtering) -->
        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <Description>Disable UAC remote filtering for admin SSH</Description>
          <CommandLine>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 7. Disable Windows Update (performance: avoids background CPU/disk) -->
        <SynchronousCommand wcm:action="add">
          <Order>7</Order>
          <Description>Disable Windows Update</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Set-Service -Name wuauserv -StartupType Disabled; Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

        <!-- 8. Disable Windows Defender real-time protection (performance) -->
        <SynchronousCommand wcm:action="add">
          <Order>8</Order>
          <Description>Disable Defender real-time</Description>
          <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>

      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
