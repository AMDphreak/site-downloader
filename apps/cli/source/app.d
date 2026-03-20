import std.stdio;
import std.getopt;
import std.array;
import std.algorithm;
import std.string;
import archiver;
import archiver.profiles;
import browser_session;

void main(string[] args)
{
    string url;
    string output;
    int depth = 2;
    bool listProfiles;
    bool downloadSocial = false;
    string cookies;
    bool useBrowserSession = false;
    string browserName = "auto";
    bool waitless = false;

    auto helpInformation = getopt(args, "url|u", "The URL to archive", &url,
            "output|o", "Output directory (default: <domain>)", &output, "depth|d",
            "Max recursion depth (default: 2)", &depth, "list-profiles|l",
            "List available browser profiles", &listProfiles, "include-social|s",
            "Include social media assets in archive (default: false)", &downloadSocial,
            "cookies|c", "Cookies to use for requests (e.g. 'session_id=123; other=456')", &cookies,
            "use-browser-session|b", "Automatically extract cookies from default browser", &useBrowserSession,
            "browser-name", "Specific browser to extract cookies from (chrome, edge, firefox, brave, auto)", &browserName,
            "waitless|w", "Skip the prompt to select the browser window", &waitless);

    // Parse positional arguments if flags weren't used
    if (url.empty && args.length > 1) {
        url = args[1];
    }
    if (output.empty && args.length > 2) {
        output = args[2];
    }

    if (helpInformation.helpWanted)
    {
        writeln("Usage: site-downloader-cli [URL] [OUTPUT_DIR] [OPTIONS]\n");
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

    bool needsUrlExtraction = url.empty;
    bool needsCookieExtraction = useBrowserSession && cookies.empty;

    if (needsUrlExtraction || needsCookieExtraction) {
        if (!waitless) {
            writeln("\n[!] Please click/focus your desired browser window, then switch back here and press ENTER to continue...");
            stdout.flush();
            readln();
        }
        
        if (needsUrlExtraction) {
            url = getCookiesForDomain("EXTRACT_URL", browserName, true);
            if (url.empty) {
                writeln("Failed to extract URL from the browser. Please provide a URL manually.");
                writeln("\nUsage: site-downloader-cli [URL] [OUTPUT_DIR] [OPTIONS]\n");
                defaultGetoptPrinter("Site Archiver CLI", helpInformation.options);
                return;
            }
            writeln("Extracted URL: ", url);
        }
    }

    if (url.empty) {
        writeln("Usage: site-downloader-cli [URL] [OUTPUT_DIR] [OPTIONS]\n");
        defaultGetoptPrinter("Site Archiver CLI", helpInformation.options);
        return;
    }

    // Extract domain name for cookie extraction and default output directory
    string domain = url;
    if (domain.startsWith("http://")) domain = domain[7..$];
    else if (domain.startsWith("https://")) domain = domain[8..$];
    
    auto slashIdx = domain.indexOf('/');
    if (slashIdx != -1) domain = domain[0..slashIdx];
    
    auto colonIdx = domain.indexOf(':');
    if (colonIdx != -1) domain = domain[0..colonIdx];

    // Default output to domain name if not provided
    if (output.empty) {
        output = domain;
        if (output.empty) output = "archive_output";
    }

    if (needsCookieExtraction) {
        try {
            string extractedCookies = getCookiesForDomain(domain, browserName);
            if (!extractedCookies.empty) {
                cookies = extractedCookies;
            }
        } catch (Exception e) {
            writeln("Failed to parse URL for cookie extraction: ", e.msg);
        }
    }

    writeln("Starting archive of ", url);
    auto sa = new SiteArchiver(url, output, downloadSocial, cookies);
    sa.archive(depth);
    writeln("Finished archiving.");
}
