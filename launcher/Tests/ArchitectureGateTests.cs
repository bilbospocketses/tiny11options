using System.Runtime.InteropServices;
using Tiny11Options.Launcher.Interop;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

/// <summary>
/// A2 (v1.0.3) regression guards: launcher startup must reject non-x64 hosts
/// with a clear message before any WebView2 / pwsh / Velopack code runs.
/// </summary>
public class ArchitectureGateTests
{
    [Fact]
    public void X64_HostIsAllowed()
    {
        Assert.Null(ArchitectureGate.CheckSupportedHost(Architecture.X64));
    }

    [Theory]
    [InlineData(Architecture.Arm64)]
    [InlineData(Architecture.Arm)]
    [InlineData(Architecture.X86)]
    public void NonX64_HostIsRejected(Architecture osArch)
    {
        var msg = ArchitectureGate.CheckSupportedHost(osArch);
        Assert.NotNull(msg);
        Assert.NotEmpty(msg!);
    }

    [Fact]
    public void RejectionMessage_NamesTheHostArchitecture()
    {
        // Critical for diagnosis: the message must mention the architecture
        // we're rejecting, so the user knows whether we picked them up as
        // Arm64 vs Arm vs X86 (and so a future report can be reproduced).
        var arm64Msg = ArchitectureGate.CheckSupportedHost(Architecture.Arm64);
        Assert.Contains("Arm64", arm64Msg);
    }

    [Fact]
    public void RejectionMessage_PointsToTheLegacyPwshEntrypoint()
    {
        // A2's whole point: arm64 users SHOULDN'T be left at a dead end. The
        // build pipeline still works on arm64 source ISOs; the message must
        // tell them how to use it (pwsh -File tiny11maker.ps1 from cmd.exe
        // or Windows PowerShell 5.1, NOT pwsh -- see tiny11maker.ps1:92).
        var msg = ArchitectureGate.BuildUnsupportedMessage(Architecture.Arm64);
        Assert.Contains("tiny11maker.ps1", msg);
        // Must explicitly steer away from pwsh-from-pwsh to avoid the 25H2
        // product-key-validation issue documented in tiny11maker.ps1:101-114.
        Assert.Contains("cmd.exe", msg);
        Assert.Contains("Windows PowerShell 5.1", msg);
    }

    [Fact]
    public void RejectionMessage_AcknowledgesArmBuildPipelineSupport()
    {
        // The build pipeline DOES support arm64 source ISOs (Core mode arch
        // detection + arm64 WinSxS keep list); rejection is launcher-only.
        // The message should be honest about that so users aren't misled
        // into thinking arm64 source ISOs are unsupported.
        var msg = ArchitectureGate.BuildUnsupportedMessage(Architecture.Arm64);
        Assert.Contains("supports arm64 source ISOs", msg);
    }

    [Fact]
    public void CheckCurrentHost_ReturnsNullOnX64TestHost()
    {
        // Tests run on the same x64 host that builds the launcher; this is a
        // sanity check that the production OSArchitecture path lights up.
        // If a future CI run executes on arm64, this test will flip and the
        // failure will be a clear "we just changed test-host arch" signal.
        if (RuntimeInformation.OSArchitecture == Architecture.X64)
        {
            Assert.Null(ArchitectureGate.CheckCurrentHost());
        }
        else
        {
            Assert.NotNull(ArchitectureGate.CheckCurrentHost());
        }
    }
}
