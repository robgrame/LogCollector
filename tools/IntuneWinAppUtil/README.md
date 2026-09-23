# Microsoft Win32 Content Prep Tool

Download the official `IntuneWinAppUtil.exe` from:

https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

Place the executable in this directory. Git ignores the binary because Microsoft distributes
it separately; `scripts\New-IntunePackage.ps1` discovers it here automatically and verifies
its Authenticode signature before execution.
