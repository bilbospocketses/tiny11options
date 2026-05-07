using System;
using System.Windows;

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
        app.Run();
        return 0;
    }
}
