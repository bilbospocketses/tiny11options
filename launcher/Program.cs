using System;

namespace Tiny11Options.Launcher;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            return Headless.HeadlessRunner.Run(args);
        }

        var app = new App();
        app.InitializeComponent();  // Loads App.xaml; without this, StartupUri is never set.
        return app.Run();
    }
}
