using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Updates;

public record UpdateInfo(string Version, string Changelog);

public interface IUpdateSource
{
    Task<UpdateInfo?> CheckAsync();
    Task ApplyAndRestartAsync();
}
