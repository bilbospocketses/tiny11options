using System;
using System.Windows;
using Tiny11Options.Launcher.Interop;
using Velopack;

namespace Tiny11Options.Launcher;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // A2 (v1.0.3) architecture gate: this exe is win-x64 only; fail loudly on
        // arm64 hosts (PRISM emulates X64 silently otherwise -- see ArchitectureGate).
        // Headless mode writes to STDERR; GUI mode shows a MessageBox before exit.
        // Exit code 2 distinguishes arch-rejection from genuine failure (exit 1).
        var archRejection = ArchitectureGate.CheckCurrentHost();
        if (archRejection != null)
        {
            if (args.Length > 0)
            {
                Console.Error.WriteLine(archRejection);
            }
            else
            {
                MessageBox.Show(
                    archRejection,
                    "tiny11options - unsupported architecture",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            return 2;
        }

        // Velopack hooks: must run BEFORE any other startup code so install/update events fire.
        VelopackApp.Build().Run();

        if (args.Length > 0)
        {
            return Headless.HeadlessRunner.Run(args);
        }

        var app = new App();
        app.InitializeComponent();  // Loads App.xaml; without this, StartupUri is never set.
        return app.Run();
    }
}
