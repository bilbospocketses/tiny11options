using System;
using Velopack;

namespace Tiny11Options.Launcher;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Velopack hooks: must run BEFORE any other startup code so install/update events fire.
        VelopackApp.Build()
            .WithFirstRun(_ => { /* nothing on first run yet */ })
            .Run();

        if (args.Length > 0)
        {
            return Headless.HeadlessRunner.Run(args);
        }

        var app = new App();
        app.InitializeComponent();  // Loads App.xaml; without this, StartupUri is never set.
        return app.Run();
    }
}
