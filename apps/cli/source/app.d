import std.stdio;
import std.getopt;
import std.array;
import archiver;
import archiver.profiles;

void main(string[] args)
{
    string url;
    string output = "archives";
    int depth = 2;
    bool listProfiles;
    bool downloadSocial = false;

    auto helpInformation = getopt(args, "url|u", "The URL to archive", &url,
            "output|o", "Output directory (default: archives)", &output, "depth|d",
            "Max recursion depth (default: 2)", &depth, "list-profiles|l",
            "List available browser profiles", &listProfiles, "include-social|s",
            "Include social media assets in archive (default: false)", &downloadSocial);

    if (helpInformation.helpWanted || (url.empty && !listProfiles))
    {
        defaultGetoptPrinter("Site Archiver CLI", helpInformation.options);
        return;
    }

    if (listProfiles)
    {
        auto profiles = findChromiumProfiles();
        writeln("Available Chromium Profiles:");
        foreach (i, p; profiles)
        {
            writefln("[%d] %s (%s) - %s", i, p.name, p.browser, p.path);
        }
        return;
    }

    writeln("Starting archive of ", url);
    auto sa = new SiteArchiver(url, output, downloadSocial);
    sa.archive(depth);
    writeln("Finished archiving.");
}
