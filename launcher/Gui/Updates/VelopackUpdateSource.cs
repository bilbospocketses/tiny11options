using System.Threading.Tasks;
using Velopack;
using Velopack.Sources;

namespace Tiny11Options.Launcher.Gui.Updates;

public class VelopackUpdateSource : IUpdateSource
{
    private readonly UpdateManager _manager;

    public VelopackUpdateSource(string githubRepo)
    {
        var src = new GithubSource(githubRepo, accessToken: null, prerelease: false);
        _manager = new UpdateManager(src);
    }

    public async Task<UpdateInfo?> CheckAsync()
    {
        if (!_manager.IsInstalled) return null;
        var info = await _manager.CheckForUpdatesAsync();
        if (info is null) return null;
        return new UpdateInfo(
            info.TargetFullRelease.Version.ToString(),
            info.TargetFullRelease.NotesMarkdown ?? "");
    }

    public async Task ApplyAndRestartAsync()
    {
        var info = await _manager.CheckForUpdatesAsync();
        if (info is null) return;
        await _manager.DownloadUpdatesAsync(info);
        _manager.ApplyUpdatesAndRestart(info);
    }
}
